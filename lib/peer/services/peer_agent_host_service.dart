/// Agent-over-Peer 提供方（host）服务。
///
/// 运行在「被访问」的一侧（如桌面）。监听配对设备通过 P2P 加密通道发来的
/// 控制消息：
/// - `agent_list_req`：返回本机所有「本地 agent 且允许外部访问」的列表。
/// - `agent_chat`：在本机用 [ChatService] 跑对应本地 agent，流式把文本块经
///   `agent_chunk` 回传，完成后发 `agent_done`，出错发 `agent_error`。
/// - `agent_cancel`：取消正在进行的请求。
///
/// 每个来源设备的会话历史保存在独立 channel `peer__{peerId}__{agentId}` 下，
/// 天然提供多轮上下文；该 channel 会以「Agent 名 ← 来源设备名」的形式出现在
/// 本机被共享 agent 的会话列表里（与旧 ACP 远程连接的行为保持一致），让用户
/// 能看到本机 agent 被配对设备访问时产生的独立会话记录。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../services/acp_agent_connection.dart';
import '../../services/chat_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../service_locator.dart' show getIt, navigatorKey;
import '../widgets/peer_agent_share_dialog.dart';
import 'peer_connection_manager.dart';
import 'peer_storage_service.dart';

/// 桌面 peer-agent 会话 channelId 前缀。用于标识本机作为 host 时、为来自配对
/// 设备的请求维护的独立入站会话。
const String kPeerAgentChannelPrefix = 'peer__';

/// 构造一个来源设备 + agent（+ 来源端会话）的入站会话 channelId。
///
/// [clientSessionId] 为来源设备上的会话标识：传入时，每个来源会话映射到独立的
/// host channel，从而让来源端「新开会话」在本机也得到一条干净、无历史的新会话；
/// 不传时回退到按「设备 + agent」聚合的旧 channel（兼容旧版客户端）。
String peerAgentChannelId(String peerId, String agentId, [String? clientSessionId]) {
  final base = '$kPeerAgentChannelPrefix${peerId}__$agentId';
  if (clientSessionId == null || clientSessionId.isEmpty) return base;
  // 清洗来源会话 id，避免空白/异常字符影响 channelId。
  final safe = clientSessionId.replaceAll(RegExp(r'\s+'), '_');
  return '${base}__s_$safe';
}

/// 判断某 channelId 是否为 peer-agent 隐藏会话。
bool isPeerAgentChannel(String? channelId) =>
    channelId != null && channelId.startsWith(kPeerAgentChannelPrefix);

class PeerAgentHostService {
  PeerAgentHostService._();
  static final PeerAgentHostService instance = PeerAgentHostService._();

  static const _tag = 'PeerAgentHost';
  final _log = LoggerService();

  StreamSubscription<PeerControlEvent>? _sub;
  bool _running = false;

  /// 正在进行的请求的取消令牌（requestId → token）。
  final Map<String, ACPCancellationToken> _activeRequests = {};

  LocalDatabaseService get _db => getIt<LocalDatabaseService>();
  ChatService get _chat => getIt<ChatService>();

  void start() {
    if (_running) return;
    _running = true;
    _sub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _log.info('PeerAgentHostService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    for (final t in _activeRequests.values) {
      t.cancel();
    }
    _activeRequests.clear();
  }

  void _onControl(PeerControlEvent event) {
    switch (event.type) {
      case 'agent_list_req':
        unawaited(_handleListReq(event.peerId));
        break;
      case 'agent_chat':
        unawaited(_handleChat(event.peerId, event.data));
        break;
      case 'agent_cancel':
        _handleCancel(event.data);
        break;
    }
  }

  Future<void> _handleListReq(String peerId) async {
    // 先按当前分享决定推送一次（未确认的设备会拿到空列表），随后视情况弹窗确认。
    await pushAgentList(peerId);
    unawaited(_maybePromptShareDecision(peerId));
  }

  /// 按「分享给该设备」的决定构建并推送可访问的 agent 列表。
  ///
  /// 设置页修改分享开关、或用户在弹窗中确认后，也通过此方法把最新列表推给对端，
  /// 对端据此即时增删本地的 peer agent。
  Future<void> pushAgentList(String peerId) async {
    try {
      final eligible = await _eligibleAgents();
      final sharedIds = await PeerStorageService().getSharedAgentIds(peerId);
      final shared = eligible.where((a) => sharedIds.contains(a.id)).toList();

      final exposed = <Map<String, dynamic>>[];
      // 所有头像共享一个传输预算：agent_list_resp 是单条控制消息，受帧大小限制，
      // 超预算的头像不附带字节，由对端回退到默认头像。
      var avatarBudget = _avatarBudgetBytes;
      for (final a in shared) {
        final entry = <String, dynamic>{
          'id': a.id,
          'name': a.name,
          'avatar': a.avatar,
          'bio': a.bio,
          'capabilities': a.capabilities,
        };
        // 头像若为本机文件（用户上传的自定义图片），对端无法访问该路径，
        // 故把图片字节一并打包发送，由对端落地为本地文件后展示。
        avatarBudget -= await _attachAvatarData(a.avatar, entry, avatarBudget);
        exposed.add(entry);
      }
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_list_resp',
        'agents': exposed,
      });
      _log.debug('Sent ${exposed.length} shared agents to $peerId', tag: _tag);
    } catch (e) {
      _log.warning('Failed to push agent list: $e', tag: _tag);
    }
  }

  /// 本机所有「本地且允许外部访问」的 agent —— 可被分享的候选集。
  Future<List<RemoteAgent>> _eligibleAgents() async {
    final agents = await _db.getAllRemoteAgents();
    return agents.where((a) => a.isLocal && a.allowExternalAccess).toList();
  }

  /// 正在弹出分享确认框的设备，避免重连/重复请求时弹出多个对话框。
  final Set<String> _promptingPeers = {};

  /// 首次连接某设备且存在可分享 agent 时，弹窗让用户确认要分享哪些。
  ///
  /// 已确认过的设备（[PeerStorageService.hasAnyAgentShare] 为真）不再弹窗：之后
  /// 新开放的 agent 默认不分享，由用户到设备设置页手动开启。
  Future<void> _maybePromptShareDecision(String peerId) async {
    if (_promptingPeers.contains(peerId)) return;
    try {
      if (await PeerStorageService().hasAnyAgentShare(peerId)) return;
      final eligible = await _eligibleAgents();
      if (eligible.isEmpty) return;

      _promptingPeers.add(peerId);
      final deviceName = await _peerDisplayName(peerId);
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;

      final result = await showPeerAgentShareDialog(
        context: ctx,
        deviceName: deviceName,
        // 默认全勾选（用户可取消），符合「确认即分享全部」的预期。
        agents: eligible
            .map((a) => PeerShareAgentEntry.fromAgent(a, initiallyShared: true))
            .toList(),
      );

      if (result == null) return; // 用户取消：不写决定，下次连接再次询问
      await PeerStorageService().setAgentShares(peerId, result);
      await pushAgentList(peerId);
    } catch (e) {
      _log.warning('Failed to prompt share decision: $e', tag: _tag);
    } finally {
      _promptingPeers.remove(peerId);
    }
  }

  /// 单个头像随控制消息传输的体积上限（base64 前的原始字节）。
  static const int _maxAvatarBytes = 256 * 1024;

  /// 单条 agent_list_resp 中所有头像字节的总预算，避免拼包后超出帧大小限制。
  static const int _avatarBudgetBytes = 2 * 1024 * 1024;

  /// 若 [avatar] 是本机文件路径，读取其字节并以 base64 写入 [entry]
  /// （`avatar_data` + `avatar_ext`）。emoji / asset / 网络 URL 无需处理。
  /// 返回本次实际占用的字节数（未附带时为 0），供调用方扣减总预算。
  Future<int> _attachAvatarData(
      String avatar, Map<String, dynamic> entry, int budget) async {
    if (!avatar.startsWith('/')) return 0; // 非本机绝对路径，对端可直接解析
    try {
      final file = File(avatar);
      if (!await file.exists()) return 0;
      final len = await file.length();
      if (len <= 0 || len > _maxAvatarBytes || len > budget) return 0;
      final bytes = await file.readAsBytes();
      var ext = avatar.contains('.') ? avatar.split('.').last.toLowerCase() : 'png';
      if (ext.length > 5) ext = 'png';
      entry['avatar_data'] = base64Encode(bytes);
      entry['avatar_ext'] = ext;
      return len;
    } catch (e) {
      _log.warning('Failed to attach avatar data for $avatar: $e', tag: _tag);
      return 0;
    }
  }

  Future<void> _handleChat(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String?;
    final agentId = data['agent_id'] as String?;
    final message = data['message'] as String? ?? '';
    final clientSessionId = data['session_id'] as String?;
    if (requestId == null || agentId == null) return;

    final token = ACPCancellationToken();
    _activeRequests[requestId] = token;

    try {
      final agent = await _db.getRemoteAgentById(agentId);
      if (agent == null || !agent.isLocal || !agent.allowExternalAccess) {
        await _sendError(peerId, requestId, 'Agent not available for external access');
        return;
      }

      final channelId = peerAgentChannelId(peerId, agentId, clientSessionId);
      final userName = await _peerDisplayName(peerId);
      final userId = 'peer:$peerId';

      // 为该来源设备的入站会话维护持久化 channel（与旧 ACP 远程连接逻辑对齐），
      // 标题统一标注「Agent 名 ← 来源设备名」，使本机能在会话列表中分辨出这条
      // 会话来自哪个配对设备。channel 不存在则创建；已存在但标题未正确标注来源
      // 设备（如历史遗留的通用名称、或对端设备改名）时则刷新标题。
      final sessionTitle = '${agent.name} ← $userName';
      try {
        final existing = await _db.getChannelById(channelId);
        if (existing == null) {
          final channel = Channel.withMemberIds(
            id: channelId,
            name: sessionTitle,
            type: 'dm',
            memberIds: [userId, agentId],
            isPrivate: false,
          );
          await _db.createChannel(channel, userId);
          _log.debug('Created peer session channel: $channelId', tag: _tag);
        } else if (existing.name != sessionTitle) {
          await _db.updateChannel(existing.copyWith(name: sessionTitle));
          _log.debug('Refreshed peer session title: $channelId -> $sessionTitle', tag: _tag);
        }
      } catch (e) {
        _log.warning('Failed to ensure peer session channel: $e', tag: _tag);
      }

      final response = await _chat.sendMessageToAgent(
        content: message,
        agent: agent,
        userId: userId,
        userName: userName,
        channelId: channelId,
        acpCancellationToken: token,
        onStreamChunk: (chunk) {
          unawaited(PeerConnectionManager.instance.sendControl(peerId, {
            'type': 'agent_chunk',
            'request_id': requestId,
            'content': chunk,
          }));
        },
      );

      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_done',
        'request_id': requestId,
        'content': response?.content ?? '',
        'message_id': response?.id,
        'metadata': response?.metadata,
      });
    } catch (e) {
      _log.warning('agent_chat failed: $e', tag: _tag);
      await _sendError(peerId, requestId, e.toString());
    } finally {
      _activeRequests.remove(requestId);
    }
  }

  void _handleCancel(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    _activeRequests[requestId]?.cancel();
  }

  Future<void> _sendError(String peerId, String requestId, String message) async {
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_error',
      'request_id': requestId,
      'message': message,
    });
  }

  Future<String> _peerDisplayName(String peerId) async {
    try {
      final peers = await PeerStorageService().loadAllPeers();
      for (final p in peers) {
        if (p.id == peerId) return p.deviceName;
      }
    } catch (_) {}
    return 'Paired Device';
  }
}

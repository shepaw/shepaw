/// Agent-over-Peer 提供方（host）服务。
///
/// 运行在「被访问」的一侧（如桌面）。监听配对设备通过 P2P 加密通道发来的
/// 控制消息：
/// - `agent_list_req`：返回本机所有「本地 agent 且允许外部访问」的列表。
/// - `agent_chat`：在本机用 [ChatService] 跑对应本地 agent，流式把文本块经
///   `agent_chunk` 回传，完成后发 `agent_done`，出错发 `agent_error`。
/// - `agent_cancel`：取消正在进行的请求。
///
/// 每个来源设备的会话历史保存在隐藏 channel `peer__{peerId}__{agentId}` 下，
/// 天然提供多轮上下文；该 channel 会从本机自己的会话列表中过滤掉。
library;

import 'dart:async';

import '../../services/acp_agent_connection.dart';
import '../../services/chat_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../../service_locator.dart' show getIt;
import 'peer_connection_manager.dart';
import 'peer_storage_service.dart';

/// 桌面 peer-agent 会话 channelId 前缀。用于把这些会话从本机会话列表过滤掉。
const String kPeerAgentChannelPrefix = 'peer__';

/// 构造一个来源设备 + agent 的隐藏 channelId。
String peerAgentChannelId(String peerId, String agentId) =>
    '$kPeerAgentChannelPrefix${peerId}__$agentId';

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
    try {
      final agents = await _db.getAllRemoteAgents();
      final exposed = agents
          .where((a) => a.isLocal && a.allowExternalAccess)
          .map((a) => {
                'id': a.id,
                'name': a.name,
                'avatar': a.avatar,
                'bio': a.bio,
                'capabilities': a.capabilities,
              })
          .toList();
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_list_resp',
        'agents': exposed,
      });
      _log.debug('Sent ${exposed.length} exposed agents to $peerId', tag: _tag);
    } catch (e) {
      _log.warning('Failed to handle agent_list_req: $e', tag: _tag);
    }
  }

  Future<void> _handleChat(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String?;
    final agentId = data['agent_id'] as String?;
    final message = data['message'] as String? ?? '';
    if (requestId == null || agentId == null) return;

    final token = ACPCancellationToken();
    _activeRequests[requestId] = token;

    try {
      final agent = await _db.getRemoteAgentById(agentId);
      if (agent == null || !agent.isLocal || !agent.allowExternalAccess) {
        await _sendError(peerId, requestId, 'Agent not available for external access');
        return;
      }

      final channelId = peerAgentChannelId(peerId, agentId);
      final userName = await _peerDisplayName(peerId);

      final response = await _chat.sendMessageToAgent(
        content: message,
        agent: agent,
        userId: 'peer:$peerId',
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

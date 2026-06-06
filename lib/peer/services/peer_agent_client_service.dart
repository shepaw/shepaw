/// Agent-over-Peer 消费方（client）服务。
///
/// 运行在「访问别人 agent」的一侧（如手机）。职责：
/// - 配对设备连上后，自动向其请求「可外部访问的本地 agent 列表」，并把结果
///   落库为 `protocol == ProtocolType.peer` 的 [RemoteAgent]，使其像普通 agent
///   一样出现在会话列表。
/// - 设备断开时把这些 agent 标记为离线；删除配对时清理对应 agent。
/// - 提供 [sendChat]：把用户消息通过 P2P 通道发给对端，流式接收回复。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../models/remote_agent.dart';
import '../../services/acp_agent_connection.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../service_locator.dart' show getIt;
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import 'peer_connection_manager.dart';

/// peer-agent 在本地 `agents` 表中的稳定 id（保证重复注入是 upsert 而非新增）。
String peerAgentLocalId(String peerId, String remoteAgentId) =>
    'peeragent_${peerId}_$remoteAgentId';

/// [PeerAgentClientService.sendChat] 的结果。
class PeerChatResult {
  final String content;
  final Map<String, dynamic>? metadata;
  PeerChatResult({required this.content, this.metadata});
}

class _PendingRequest {
  final void Function(String chunk)? onChunk;
  final Completer<PeerChatResult> completer = Completer<PeerChatResult>();
  _PendingRequest(this.onChunk);
}

class PeerAgentClientService {
  PeerAgentClientService._();
  static final PeerAgentClientService instance = PeerAgentClientService._();

  static const _tag = 'PeerAgentClient';
  final _log = LoggerService();
  final _uuid = const Uuid();

  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  StreamSubscription<void>? _peerListSub;
  bool _running = false;

  /// 进行中的请求（requestId → pending）。
  final Map<String, _PendingRequest> _pending = {};

  LocalDatabaseService get _db => getIt<LocalDatabaseService>();
  final _fileStorage = LocalFileStorageService();

  Future<void> start() async {
    if (_running) return;
    _running = true;

    _controlSub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _eventSub = PeerConnectionManager.instance.events.listen(_onConnectionEvent);
    _peerListSub =
        PeerConnectionManager.instance.peerListChanged.listen((_) => _reconcileDeletions());

    // 对已连接的 peer 立即拉取一次列表，并清理已删除配对的残留 agent。
    await _reconcileDeletions();
    for (final peerId in PeerConnectionManager.instance.connectedPeerIds) {
      _requestAgentList(peerId);
    }
    _log.info('PeerAgentClientService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _controlSub?.cancel();
    _controlSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _peerListSub?.cancel();
    _peerListSub = null;
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('PeerAgentClientService stopped'));
      }
    }
    _pending.clear();
  }

  // ── 发送（消费方 → 提供方） ────────────────────────────────────────────

  /// 通过 P2P 通道把消息发给对端的本地 agent，流式接收回复。
  ///
  /// 对端未连接时立即抛错。[cancelToken] 触发时会向对端发送 `agent_cancel`。
  Future<PeerChatResult> sendChat({
    required String peerId,
    required String remoteAgentId,
    required String message,
    String? sessionId,
    void Function(String chunk)? onChunk,
    ACPCancellationToken? cancelToken,
  }) async {
    final requestId = _uuid.v4();
    final pending = _PendingRequest(onChunk);
    _pending[requestId] = pending;

    cancelToken?.onCancelled = () {
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_cancel',
        'request_id': requestId,
      }));
      final p = _pending.remove(requestId);
      if (p != null && !p.completer.isCompleted) {
        p.completer.complete(PeerChatResult(content: '[Stopped]'));
      }
    };

    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_chat',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'message': message,
      // 把本端会话 id 透传给对端，使对端按会话隔离历史：本端「新开会话」
      // 在对端也得到一条干净、无历史的新会话。
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
    });

    if (!sent) {
      _pending.remove(requestId);
      throw Exception('配对设备未连接，无法发送');
    }

    return pending.completer.future;
  }

  // ── 控制消息处理 ───────────────────────────────────────────────────────

  void _onControl(PeerControlEvent event) {
    switch (event.type) {
      case 'agent_list_resp':
        unawaited(_onAgentList(event.peerId, event.data));
        break;
      case 'agent_chunk':
        _onChunk(event.data);
        break;
      case 'agent_done':
        _onDone(event.data);
        break;
      case 'agent_error':
        _onError(event.data);
        break;
    }
  }

  void _onChunk(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    final content = data['content'] as String? ?? '';
    if (requestId == null) return;
    _pending[requestId]?.onChunk?.call(content);
  }

  void _onDone(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    p.completer.complete(PeerChatResult(
      content: data['content'] as String? ?? '',
      metadata: (data['metadata'] as Map?)?.cast<String, dynamic>(),
    ));
  }

  void _onError(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    p.completer.completeError(
      Exception(data['message'] as String? ?? 'Peer agent error'),
    );
  }

  // ── agent 列表注入 / 清理 ──────────────────────────────────────────────

  void _onConnectionEvent(PeerConnectionEvent event) {
    if (event.type == PeerConnectionEventType.connected) {
      _requestAgentList(event.peerId);
    } else if (event.type == PeerConnectionEventType.disconnected) {
      unawaited(_markPeerAgentsOffline(event.peerId));
    }
  }

  void _requestAgentList(String peerId) {
    unawaited(PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_list_req',
    }));
  }

  Future<void> _onAgentList(String peerId, Map<String, dynamic> data) async {
    final list = (data['agents'] as List?) ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final seenRemoteIds = <String>{};
    final peerName = await _peerDisplayName(peerId);

    try {
      for (final raw in list) {
        if (raw is! Map) continue;
        final remoteId = raw['id'] as String?;
        if (remoteId == null) continue;
        seenRemoteIds.add(remoteId);

        final localId = peerAgentLocalId(peerId, remoteId);
        final existing = await _db.getRemoteAgentById(localId);
        final capabilities = (raw['capabilities'] as List?)?.cast<String>() ?? const [];
        final avatar = await _resolvePeerAvatar(raw, existing);

        final agent = RemoteAgent(
          id: localId,
          name: raw['name'] as String? ?? 'Agent',
          avatar: avatar,
          bio: raw['bio'] as String?,
          token: '',
          endpoint: 'peer://$peerId/$remoteId',
          protocol: ProtocolType.peer,
          connectionType: ConnectionType.websocket,
          status: AgentStatus.online,
          connectedAt: now,
          capabilities: capabilities,
          metadata: {
            'source_peer_id': peerId,
            'source_peer_name': peerName,
            'remote_agent_id': remoteId,
            // 保留本地头像自定义标记，使其在每次同步后依然生效。
            if (existing?.metadata['avatar_overridden'] == true)
              'avatar_overridden': true,
          },
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        );

        if (existing == null) {
          await _db.createRemoteAgent(agent);
        } else {
          await _db.updateRemoteAgent(agent);
        }
      }

      // 对端不再暴露的 agent → 删除。
      await _removeStalePeerAgents(peerId, keep: seenRemoteIds);

      _log.debug('Injected ${seenRemoteIds.length} peer agents from $peerId', tag: _tag);
      PeerConnectionManager.instance.notifyPeerListChanged();
    } catch (e) {
      _log.warning('Failed to inject peer agents: $e', tag: _tag);
    }
  }

  /// 解析对端 agent 的头像值，落地为本地可展示的形式。
  ///
  /// - 对端附带了图片字节（`avatar_data`）：解码后写入本地存储，返回其绝对路径；
  ///   若该 peer agent 此前已有本地头像文件，则原地覆盖以保持路径稳定、避免堆积。
  /// - 无字节：直接用 `avatar` 字符串（emoji / asset / 网络 URL 可在本端解析）；
  ///   但若它是对端的本机绝对路径，本端无法访问，回退到默认 emoji。
  Future<String> _resolvePeerAvatar(Map raw, RemoteAgent? existing) async {
    // 本地已自定义该 peer agent 头像 → 以本地为准，忽略对端分享的头像。
    final existingAvatar = existing?.avatar;
    if (existing?.metadata['avatar_overridden'] == true &&
        existingAvatar != null &&
        existingAvatar.isNotEmpty) {
      return existingAvatar;
    }

    final data = raw['avatar_data'] as String?;
    if (data != null && data.isNotEmpty) {
      try {
        final bytes = base64Decode(data);
        final ext = (raw['avatar_ext'] as String?)?.trim();
        // 复用已有本地文件（须真实存在，避免误用早期存下的对端绝对路径），原地
        // 覆盖以保持路径稳定、避免每次重连都堆积新文件。
        if (existingAvatar != null &&
            existingAvatar.startsWith('/') &&
            !existingAvatar.startsWith('http')) {
          final f = File(existingAvatar);
          if (await f.exists()) {
            await f.writeAsBytes(bytes, flush: true);
            return existingAvatar;
          }
        }
        final rel = await _fileStorage.saveImageBytes(
          bytes,
          (ext != null && ext.isNotEmpty) ? ext : 'png',
        );
        return await _fileStorage.getFullPath(rel);
      } catch (e) {
        _log.warning('Failed to persist peer avatar: $e', tag: _tag);
        // 落地失败则继续走下面的字符串回退。
      }
    }

    final avatar = raw['avatar'] as String? ?? '🤖';
    // 对端的本机绝对路径在本端不存在，回退默认 emoji。
    if (avatar.startsWith('/') && !avatar.startsWith('http')) return '🤖';
    return avatar.isEmpty ? '🤖' : avatar;
  }

  Future<void> _markPeerAgentsOffline(String peerId) async {
    try {
      final agents = await _db.getAllRemoteAgents();
      for (final a in agents) {
        if (a.protocol == ProtocolType.peer && a.sourcePeerId == peerId) {
          await _db.updateRemoteAgentStatus(a.id, 'offline');
        }
      }
      PeerConnectionManager.instance.notifyPeerListChanged();
    } catch (e) {
      _log.warning('Failed to mark peer agents offline: $e', tag: _tag);
    }
  }

  Future<void> _removeStalePeerAgents(String peerId, {required Set<String> keep}) async {
    final agents = await _db.getAllRemoteAgents();
    for (final a in agents) {
      if (a.protocol == ProtocolType.peer &&
          a.sourcePeerId == peerId &&
          !keep.contains(a.remoteAgentId)) {
        await _db.deleteRemoteAgent(a.id);
      }
    }
  }

  Future<String> _peerDisplayName(String peerId) async {
    try {
      final peers = await PeerConnectionManager.instance.getAllPeers();
      for (final p in peers) {
        if (p.id == peerId) return p.deviceName;
      }
    } catch (_) {}
    return '配对设备';
  }

  /// 删除已不再配对的设备遗留的 peer agent。
  Future<void> _reconcileDeletions() async {
    try {
      final pairedIds =
          (await PeerConnectionManager.instance.getAllPeers()).map((p) => p.id).toSet();
      final agents = await _db.getAllRemoteAgents();
      var changed = false;
      for (final a in agents) {
        if (a.protocol == ProtocolType.peer &&
            (a.sourcePeerId == null || !pairedIds.contains(a.sourcePeerId))) {
          await _db.deleteRemoteAgent(a.id);
          changed = true;
        }
      }
      if (changed) PeerConnectionManager.instance.notifyPeerListChanged();
    } catch (e) {
      _log.warning('reconcileDeletions failed: $e', tag: _tag);
    }
  }
}

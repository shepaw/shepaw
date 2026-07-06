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

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../models/acp_protocol.dart';
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

/// 「已同步的远端 peer 会话」在本地 channel id 上的前缀。
///
/// 本地 channel id = `psess_<远端 sessionId>`。发消息时会剥离前缀，把裸的远端
/// sessionId 作为 `session_id` 发回对端，从而命中 acp-proxy 预置的映射并 resume
/// 到真实的上游会话——保证本地会话与远端一一对应、不串 session。
const String kSyncedPeerSessionPrefix = 'psess_';

/// 由远端 sessionId 生成本地已同步会话的 channel id。
String syncedPeerChannelId(String remoteSessionId) =>
    '$kSyncedPeerSessionPrefix$remoteSessionId';

/// 若 [channelId] 是已同步的远端会话，返回其绑定的远端 sessionId，否则返回 null。
String? remoteSessionIdFromChannelId(String channelId) =>
    channelId.startsWith(kSyncedPeerSessionPrefix)
        ? channelId.substring(kSyncedPeerSessionPrefix.length)
        : null;

/// [PeerAgentClientService.sendChat] 的结果。
class PeerChatResult {
  final String content;
  final Map<String, dynamic>? metadata;
  PeerChatResult({required this.content, this.metadata});
}

/// 对端某个 agent 已知的一条会话（由 `agent_sessions_resp` 返回）。
///
/// [sessionId] 是「回发给对端 `agent_chat` 的 session_id」——本端据此建立/绑定
/// 一条本地 channel，从此该会话的每条消息都用同一 session_id 打过去，保证与远端
/// 会话一一对应、不串。
class PeerRemoteSession {
  final String sessionId;
  final String? title;
  final DateTime? updatedAt;

  PeerRemoteSession({required this.sessionId, this.title, this.updatedAt});

  static PeerRemoteSession? fromJson(Map<String, dynamic> json) {
    final rawId = json['session_id'];
    final id = rawId is String
        ? rawId
        : rawId != null
            ? rawId.toString()
            : null;
    if (id == null || id.isEmpty) return null;
    DateTime? updated;
    final rawUpdated = json['updated_at'];
    if (rawUpdated is String && rawUpdated.isNotEmpty) {
      updated = DateTime.tryParse(rawUpdated);
    }
    final title = (json['title'] as String?)?.trim();
    return PeerRemoteSession(
      sessionId: id,
      title: (title != null && title.isNotEmpty) ? title : null,
      updatedAt: updated,
    );
  }
}

/// One replayed conversation turn from a peer session's transcript
/// (via `agent_session_history_resp`).
class PeerHistoryMessage {
  /// `user` or `agent`.
  final String role;
  final String content;
  final String? messageId;

  PeerHistoryMessage({required this.role, required this.content, this.messageId});

  static PeerHistoryMessage? fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String?;
    final content = json['content'] as String?;
    if (role == null || content == null) return null;
    return PeerHistoryMessage(
      role: role,
      content: content,
      messageId: json['message_id'] as String?,
    );
  }
}

/// One upstream model option from `agent_models_resp`.
class PeerAgentModel {
  final String value;
  final String displayName;
  final String description;

  PeerAgentModel({
    required this.value,
    required this.displayName,
    this.description = '',
  });

  static PeerAgentModel? fromJson(Map<String, dynamic> json) {
    final value = json['value'] as String?;
    if (value == null || value.isEmpty) return null;
    final display = (json['display_name'] as String?)?.trim();
    return PeerAgentModel(
      value: value,
      displayName: (display != null && display.isNotEmpty) ? display : value,
      description: (json['description'] as String?) ?? '',
    );
  }
}

/// Upstream model list + current selection (`agent_models_resp`).
class PeerModelsList {
  final List<PeerAgentModel> models;
  final String? current;

  const PeerModelsList({required this.models, this.current});
}

class _PendingRequest {
  final void Function(String chunk)? onChunk;
  final void Function(Map<String, dynamic>)? onActionConfirmation;
  final Completer<PeerChatResult> completer = Completer<PeerChatResult>();
  _PendingRequest(this.onChunk, this.onActionConfirmation);
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

  /// Slash-command cache (localAgentId → commands), populated by
  /// agent_commands_resp after agent_list_resp prefetches them.
  final Map<String, List<SlashCommandInfo>> _commandsCache = {};
  /// Outstanding agent_commands_req per remote agent id.
  final Map<String, Completer<List<SlashCommandInfo>>> _pendingCommands = {};
  /// Broadcast streams so the "/" palette can refresh when a prefetch completes
  /// after the chat screen is already open (peer agents have no ACP connection).
  final Map<String, StreamController<List<SlashCommandInfo>>> _slashCommandsStreams =
      {};

  /// Outstanding agent_sessions_req per remote agent id.
  final Map<String, Completer<List<PeerRemoteSession>>> _pendingSessions = {};

  /// Outstanding agent_session_history_req per "agentId::sessionId" key.
  final Map<String, Completer<List<PeerHistoryMessage>>> _pendingHistory = {};

  /// Outstanding agent_models_req per remote agent id.
  final Map<String, Completer<PeerModelsList>> _pendingModels = {};

  /// Outstanding agent_models_set_req per "agentId::model" key.
  final Map<String, Completer<bool>> _pendingModelSet = {};

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
    for (final c in _pendingSessions.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pendingSessions.clear();
    for (final c in _pendingHistory.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pendingHistory.clear();
    for (final c in _pendingCommands.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pendingCommands.clear();
    for (final c in _pendingModels.values) {
      if (!c.isCompleted) c.complete(const PeerModelsList(models: []));
    }
    _pendingModels.clear();
    for (final c in _pendingModelSet.values) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingModelSet.clear();
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
    void Function(Map<String, dynamic>)? onActionConfirmation,
    ACPCancellationToken? cancelToken,
  }) async {
    final requestId = _uuid.v4();
    final pending = _PendingRequest(onChunk, onActionConfirmation);
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
      case 'agent_approval_req':
        _onApprovalReq(event.data);
        break;
      case 'agent_commands_resp':
        _onCommandsResp(event.peerId, event.data);
        break;
      case 'agent_sessions_resp':
        _onSessionsResp(event.data);
        break;
      case 'agent_session_history_resp':
        _onSessionHistoryResp(event.data);
        break;
      case 'agent_models_resp':
        _onModelsResp(event.data);
        break;
      case 'agent_models_set_resp':
        _onModelsSetResp(event.data);
        break;
    }
  }

  /// Fetch upstream model options (`agent.models.list` relay). Returns empty
  /// list on failure/timeout. [sessionId] is the bare remote session id when
  /// scoping to a synced session; omit for the agent default.
  Future<PeerModelsList> fetchModels({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    if (_pendingModels.containsKey(remoteAgentId)) {
      return _pendingModels[remoteAgentId]!.future;
    }
    final completer = Completer<PeerModelsList>();
    _pendingModels[remoteAgentId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_models_req',
      'agent_id': remoteAgentId,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingModels.remove(remoteAgentId);
      return const PeerModelsList(models: []);
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModels.remove(remoteAgentId);
      return const PeerModelsList(models: []);
    });
  }

  void _onModelsResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final raw = (data['models'] as List?) ?? const [];
    final models = raw
        .whereType<Map<String, dynamic>>()
        .map(PeerAgentModel.fromJson)
        .whereType<PeerAgentModel>()
        .toList();
    final current = data['current'] as String?;
    final completer = _pendingModels.remove(remoteId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(PeerModelsList(models: models, current: current));
    }
  }

  /// Switch the upstream model (`agent.models.setCurrent` relay).
  Future<bool> setModel({
    required String peerId,
    required String remoteAgentId,
    required String model,
    String? sessionId,
  }) async {
    final key = '$remoteAgentId::$model';
    if (_pendingModelSet.containsKey(key)) return _pendingModelSet[key]!.future;
    final completer = Completer<bool>();
    _pendingModelSet[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_models_set_req',
      'agent_id': remoteAgentId,
      'model': model,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingModelSet.remove(key);
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModelSet.remove(key);
      return false;
    });
  }

  void _onModelsSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final model = data['model'] as String?;
    if (remoteId == null || model == null) return;
    final ok = data['ok'] == true;
    final completer = _pendingModelSet.remove('$remoteId::$model');
    if (completer != null && !completer.isCompleted) completer.complete(ok);
  }

  /// Fetch a remote session's transcript (oldest → newest) so the app can
  /// backfill local chat history when opening a synced session. Returns `[]`
  /// on failure/timeout or when the agent can't replay.
  Future<List<PeerHistoryMessage>> fetchHistory({
    required String peerId,
    required String remoteAgentId,
    required String sessionId,
  }) async {
    final key = '$remoteAgentId::$sessionId';
    if (_pendingHistory.containsKey(key)) return _pendingHistory[key]!.future;
    final completer = Completer<List<PeerHistoryMessage>>();
    _pendingHistory[key] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_session_history_req',
      'agent_id': remoteAgentId,
      'session_id': sessionId,
    });
    if (!sent) {
      _pendingHistory.remove(key);
      return const [];
    }
    return completer.future.timeout(const Duration(seconds: 45), onTimeout: () {
      _pendingHistory.remove(key);
      return const [];
    });
  }

  void _onSessionHistoryResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final sessionId = data['session_id'] as String?;
    if (remoteId == null || sessionId == null) return;
    final raw = (data['messages'] as List?) ?? const [];
    final messages = raw
        .whereType<Map<String, dynamic>>()
        .map(PeerHistoryMessage.fromJson)
        .whereType<PeerHistoryMessage>()
        .toList();
    final completer = _pendingHistory.remove('$remoteId::$sessionId');
    if (completer != null && !completer.isCompleted) completer.complete(messages);
  }

  /// Fetch an agent's known sessions from the hub (agent.sessions.list relay).
  ///
  /// Returns `[]` on failure/timeout or when the underlying agent can't
  /// enumerate sessions (graceful degrade — the UI just shows no remote list).
  Future<List<PeerRemoteSession>> fetchSessions({
    required String peerId,
    required String remoteAgentId,
  }) async {
    if (_pendingSessions.containsKey(remoteAgentId)) {
      return _pendingSessions[remoteAgentId]!.future;
    }
    final completer = Completer<List<PeerRemoteSession>>();
    _pendingSessions[remoteAgentId] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_sessions_req',
      'agent_id': remoteAgentId,
    });
    if (!sent) {
      _pendingSessions.remove(remoteAgentId);
      return const [];
    }
    return completer.future.timeout(const Duration(seconds: 10), onTimeout: () {
      _pendingSessions.remove(remoteAgentId);
      return const [];
    });
  }

  void _onSessionsResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final raw = (data['sessions'] as List?) ?? const [];
    final sessions = raw
        .whereType<Map<String, dynamic>>()
        .map(PeerRemoteSession.fromJson)
        .whereType<PeerRemoteSession>()
        .toList();
    final completer = _pendingSessions.remove(remoteId);
    if (completer != null && !completer.isCompleted) completer.complete(sessions);
  }

  /// Mirror a peer agent's remote sessions into local channels (shell only).
  ///
  /// For each remote session we create/update one local channel whose id binds
  /// the remote sessionId (see [syncedPeerChannelId]). No history is pulled
  /// here — opening the channel later resumes the real upstream session on the
  /// agent-bridge side, so context stays intact without duplicating storage.
  ///
  /// Returns the number of remote sessions synced (0 if none / not enumerable).
  Future<int> syncSessions({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String userId,
    required List<PeerRemoteSession> sessions,
  }) async {
    if (sessions.isEmpty) return 0;
    var linked = 0;
    for (final s in sessions) {
      final channelId = syncedPeerChannelId(s.sessionId);
      final name = s.title ?? 'Session';
      final existing = await _db.getChannelById(channelId);
      if (existing == null) {
        final channel = Channel.withMemberIds(
          id: channelId,
          name: name,
          type: 'dm',
          memberIds: [userId, localAgentId],
          isPrivate: true,
        );
        await _db.createChannel(channel, userId);
        linked++;
      } else {
        // Channel shell may already exist from a prior sync under a previous
        // peer-agent local id (peer re-pair / agent re-inject deletes the old
        // agent row and CASCADE-removes its channel_members, but the psess_
        // channel row survives). Re-attach the current agent + user so
        // getChannelsForAgent(localAgentId) can see it again.
        final members = await _db.getChannelMemberIds(channelId);
        var repaired = false;
        if (!members.contains(userId)) {
          await _db.addChannelMember(channelId, userId);
          repaired = true;
        }
        if (!members.contains(localAgentId)) {
          await _db.addChannelMember(channelId, localAgentId);
          repaired = true;
        }
        if (repaired) linked++;
        if (existing.name != name && name.isNotEmpty) {
          await _db.updateChannel(existing.copyWith(name: name));
        }
      }
      // Seed recency from the remote only when the channel is first created.
      // Overwriting updated_at on existing channels would clobber the local
      // "last opened session" marker (touchChannelUpdatedAt) and make re-entry
      // from the conversation list jump back to a different session.
      if (existing == null && s.updatedAt != null) {
        await _db.setChannelUpdatedAt(channelId, s.updatedAt!);
      }
    }
    _log.info(
      'Synced $linked/${sessions.length} remote session(s) for peer agent $localAgentId',
      tag: _tag,
    );
    return linked;
  }

  /// Pull a synced session's transcript from the remote and make the local
  /// channel mirror it exactly. Meant to run on every entry (pull-authoritative).
  ///
  /// Fetches the remote transcript; if it differs from what's stored locally,
  /// rebuilds the channel's messages to match. If the fetch is empty (agent
  /// can't replay / timeout), local messages are kept untouched. Returns the
  /// number of messages written, or 0 when nothing changed / local was kept.
  Future<int> syncHistory({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String agentName,
    required String channelId,
    required String userId,
    required String userName,
  }) async {
    final remoteSessionId = remoteSessionIdFromChannelId(channelId);
    if (remoteSessionId == null) return 0;

    final history = await fetchHistory(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: remoteSessionId,
    );
    if (history.isEmpty) return 0;

    // Skip the rewrite (and UI flicker) when local already matches remote.
    final existing = await _db.getChannelMessages(channelId, limit: 2000);
    final existingAsc = existing.reversed.toList();
    if (existingAsc.length == history.length) {
      var identical = true;
      for (var i = 0; i < history.length; i++) {
        final row = existingAsc[i];
        final role = (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
        if (role != history[i].role || (row['content'] as String? ?? '') != history[i].content) {
          identical = false;
          break;
        }
      }
      if (identical) return 0;
    }

    // Rebuild to mirror the remote transcript exactly.
    await _db.deleteChannelMessages(channelId);
    final baseMs = DateTime.now().millisecondsSinceEpoch - history.length * 1000;
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isUser = m.role == 'user';
      final createdAt = DateTime.fromMillisecondsSinceEpoch(baseMs + i * 1000);
      final msgId = m.messageId != null && m.messageId!.isNotEmpty
          ? 'peerhist_${m.messageId}'
          : 'peerhist_${channelId}_$i';
      await _db.createMessage(
        id: msgId,
        channelId: channelId,
        senderId: isUser ? userId : localAgentId,
        senderType: isUser ? 'user' : 'agent',
        senderName: isUser ? userName : agentName,
        content: m.content,
        createdAt: createdAt,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    _log.info(
      'Synced ${history.length} history message(s) into $channelId',
      tag: _tag,
    );
    return history.length;
  }

  /// Cached slash commands for an agent (by local agent id). Empty until the
  /// prefetch (triggered on agent_list_resp) completes.
  List<SlashCommandInfo> getSlashCommands(String localAgentId) =>
      _commandsCache[localAgentId] ?? const [];

  /// Stream of slash-command list updates for a peer agent (by local agent id).
  Stream<List<SlashCommandInfo>> slashCommandsStream(String localAgentId) {
    return _slashCommandsStreams
        .putIfAbsent(
          localAgentId,
          () => StreamController<List<SlashCommandInfo>>.broadcast(),
        )
        .stream;
  }

  /// Ensure slash commands are cached for [localAgentId]. No-op when the cache
  /// is already populated; otherwise issues agent_commands_req (e.g. on chat
  /// entry when the connect-time prefetch timed out on a cold agent-bridge).
  Future<void> ensureCommandsForLocalAgent(String localAgentId) async {
    if (_commandsCache[localAgentId]?.isNotEmpty ?? false) return;
    final agent = await _db.getRemoteAgentById(localAgentId);
    if (agent == null || !agent.isPeerAgent) return;
    final peerId = agent.sourcePeerId;
    final remoteId = agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) return;
    await fetchCommands(peerId: peerId, remoteAgentId: remoteId);
  }

  /// Fetch an agent's slash commands from the hub (agent.commands.list relay).
  Future<List<SlashCommandInfo>> fetchCommands({
    required String peerId,
    required String remoteAgentId,
  }) async {
    if (_pendingCommands.containsKey(remoteAgentId)) {
      return _pendingCommands[remoteAgentId]!.future;
    }
    final completer = Completer<List<SlashCommandInfo>>();
    _pendingCommands[remoteAgentId] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_commands_req',
      'agent_id': remoteAgentId,
    });
    if (!sent) {
      _pendingCommands.remove(remoteAgentId);
      return const [];
    }
    // Generous timeout: on a cold agent-bridge subprocess the hub now warms
    // the command cache via a throwaway session, which can take longer than
    // a simple RPC round trip (see PeerAcpClient.commands()).
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingCommands.remove(remoteAgentId);
      return const [];
    });
  }

  void _onCommandsResp(String peerId, Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final raw = (data['commands'] as List?) ?? const [];
    final commands = <SlashCommandInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        commands.add(SlashCommandInfo.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {
        // Skip malformed entries rather than dropping the whole list.
      }
    }
    final localId = peerAgentLocalId(peerId, remoteId);
    _commandsCache[localId] = commands;
    // Mirror ACP's snapshot hook so the "/" resolver can read from either path.
    ACPAgentConnection.slashCommandsSnapshotHook?.call(localId, commands);
    final stream = _slashCommandsStreams[localId];
    if (stream != null && !stream.isClosed) {
      stream.add(List.unmodifiable(commands));
    }
    final completer = _pendingCommands.remove(remoteId);
    if (completer != null && !completer.isCompleted) completer.complete(commands);
  }

  /// Tool-call approval request forwarded by the hub. Surface it to the chat
  /// UI via the active request's `onActionConfirmation` callback (same card
  /// mechanism as the direct ACP flow). The user's tap later calls
  /// [submitApproval], which replies `agent_approval_resp` over the peer
  /// channel; the hub relays it as `agent.submitResponse` to its local agent.
  void _onApprovalReq(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) {
      _log.warning('agent_approval_req: missing request_id', tag: 'PeerApproval');
      return;
    }
    final approvalId = data['approval_id'] as String? ?? '';
    final actions = data['actions'] ?? const [];
    final hasCallback = _pending[requestId]?.onActionConfirmation != null;
    _log.info(
      'agent_approval_req: approvalId=$approvalId requestId=$requestId '
      'pendingRequest=${_pending.containsKey(requestId)} hasCallback=$hasCallback '
      'actions=${actions is List ? actions.length : 0} '
      'toolKind=${data['tool_kind']} toolCallId=${data['tool_call_id']}',
      tag: 'PeerApproval',
    );
    if (!hasCallback) {
      _log.warning(
        'agent_approval_req: no onActionConfirmation for requestId=$requestId '
        '(active pending keys: ${_pending.keys.take(5).join(", ")})',
        tag: 'PeerApproval',
      );
    }
    final actionData = <String, dynamic>{
      // The card widget keys off `confirmation_id`; the hub's approval_id IS
      // the gateway's confirmation_id, so reuse it for the submit path too.
      'confirmation_id': approvalId,
      'prompt': data['prompt'] ?? '',
      'actions': data['actions'] ?? const [],
      // Marks this as a peer-relayed approval so the submit path knows to
      // reply via agent_approval_resp instead of connection.submitResponse.
      'confirmation_context': 'peer',
      if (data['tool_kind'] != null) 'tool_kind': data['tool_kind'],
      if (data['tool_call_id'] != null) 'tool_call_id': data['tool_call_id'],
    };
    _pending[requestId]?.onActionConfirmation?.call(actionData);
    _log.debug(
      'agent_approval_req: forwarded to UI confirmationId=$approvalId',
      tag: 'PeerApproval',
    );
  }

  /// Submit the user's tool-call decision back to the hub.
  Future<void> submitApproval({
    required String peerId,
    required String approvalId,
    required String selectedActionId,
    String? selectedActionLabel,
  }) async {
    _log.info(
      'submitApproval: approvalId=$approvalId actionId=$selectedActionId '
      'label=${selectedActionLabel ?? ""} peerId=$peerId',
      tag: 'PeerApproval',
    );
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_approval_resp',
      'approval_id': approvalId,
      'selected_action_id': selectedActionId,
      if (selectedActionLabel != null && selectedActionLabel.isNotEmpty)
        'selected_action_label': selectedActionLabel,
    });
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

      // Prefetch each agent's slash commands so the '/' palette works for
      // peer agents (which have no ACP connection to read them from).
      for (final remoteId in seenRemoteIds) {
        unawaited(fetchCommands(peerId: peerId, remoteAgentId: remoteId));
      }
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

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

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../models/acp_protocol.dart';
import '../../services/acp_agent_connection.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../service_locator.dart' show getIt;
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer_approval_payload.dart';
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

/// Overlap subtracted from the last history-sync watermark so borderline
/// updates are not missed across consecutive syncs.
const Duration kPeerHistorySyncOverlap = Duration(minutes: 2);

/// SharedPreferences key for the agent-level history sync watermark.
String peerHistoryLastSyncPrefsKey(String localAgentId) =>
    'peer_history_last_sync_$localAgentId';

/// 由远端 sessionId 生成本地已同步会话的 channel id。
String syncedPeerChannelId(String remoteSessionId) =>
    '$kSyncedPeerSessionPrefix$remoteSessionId';

/// 若 [channelId] 是已同步的远端会话，返回其绑定的远端 sessionId，否则返回 null。
String? remoteSessionIdFromChannelId(String channelId) =>
    channelId.startsWith(kSyncedPeerSessionPrefix)
        ? channelId.substring(kSyncedPeerSessionPrefix.length)
        : null;

/// Sessions whose transcripts should be re-fetched for an incremental sync.
///
/// When [lastSyncAt] is null (first sync), every session is dirty. Otherwise a
/// session is dirty if it has no `updatedAt` or `updatedAt >= lastSyncAt - overlap`.
/// When [prioritizeSessionId] is set, that session is moved to the front.
List<PeerRemoteSession> selectDirtySessions(
  List<PeerRemoteSession> sessions, {
  DateTime? lastSyncAt,
  Duration overlap = kPeerHistorySyncOverlap,
  String? prioritizeSessionId,
}) {
  final List<PeerRemoteSession> dirty;
  if (lastSyncAt == null) {
    dirty = List<PeerRemoteSession>.of(sessions);
  } else {
    final since = lastSyncAt.subtract(overlap);
    dirty = sessions
        .where((s) => s.updatedAt == null || !s.updatedAt!.isBefore(since))
        .toList();
  }
  final prioritize = prioritizeSessionId;
  if (prioritize != null && prioritize.isNotEmpty) {
    dirty.sort((a, b) {
      if (a.sessionId == prioritize) return -1;
      if (b.sessionId == prioritize) return 1;
      return 0;
    });
  }
  return dirty;
}

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

  /// Original send time from the standard history protocol (`created_at`).
  /// Engine-specific extraction happens in agent-bridge; the app only consumes
  /// this field.
  final DateTime? createdAt;

  PeerHistoryMessage({
    required this.role,
    required this.content,
    this.messageId,
    this.createdAt,
  });

  static PeerHistoryMessage? fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String?;
    final content = json['content'] as String?;
    if (role == null || content == null) return null;
    DateTime? createdAt;
    final rawCreated = json['created_at'];
    if (rawCreated is String && rawCreated.isNotEmpty) {
      createdAt = DateTime.tryParse(rawCreated);
    }
    return PeerHistoryMessage(
      role: role,
      content: content,
      messageId: json['message_id'] as String?,
      createdAt: createdAt,
    );
  }
}

/// Assign display timestamps for a synced peer transcript.
///
/// Preference order per message:
/// 1. Protocol [PeerHistoryMessage.createdAt] (filled by agent-bridge)
/// 2. Existing local `created_at` for the same stable id (when any remote stamp
///    exists — preserves prior good times for unstamped gaps)
/// 3. Anchor to session-level [sessionUpdatedAt] from `sessions.list`
/// 4. Preserve existing local time when no session anchor is available
/// 5. [fallbackEnd]-anchored synthetic times for brand-new rows
List<DateTime> assignPeerHistoryTimestamps(
  List<PeerHistoryMessage> history, {
  Map<String, DateTime> existingById = const {},
  DateTime? sessionUpdatedAt,
  DateTime? fallbackEnd,
  String Function(PeerHistoryMessage message, int index)? idFor,
}) {
  if (history.isEmpty) return const [];
  final anyRemote = history.any((m) => m.createdAt != null);
  final end = sessionUpdatedAt ?? fallbackEnd ?? DateTime.now();
  final out = <DateTime>[];
  for (var i = 0; i < history.length; i++) {
    final m = history[i];
    final id = idFor?.call(m, i);
    final existing = id != null ? existingById[id] : null;
    if (m.createdAt != null) {
      out.add(m.createdAt!);
    } else if (anyRemote && existing != null) {
      out.add(existing);
    } else if (sessionUpdatedAt != null) {
      final offsetFromEnd = history.length - 1 - i;
      out.add(sessionUpdatedAt.subtract(Duration(minutes: offsetFromEnd)));
    } else if (existing != null) {
      out.add(existing);
    } else {
      final offsetFromEnd = history.length - 1 - i;
      out.add(end.subtract(Duration(minutes: offsetFromEnd)));
    }
  }
  // Ensure strictly non-decreasing order so chat sorting stays stable when
  // remote stamps and anchors mix.
  for (var i = 1; i < out.length; i++) {
    if (out[i].isBefore(out[i - 1])) {
      out[i] = out[i - 1].add(const Duration(seconds: 1));
    }
  }
  return out;
}

String peerHistoryMessageId(PeerHistoryMessage m, String channelId, int index) {
  if (m.messageId != null && m.messageId!.isNotEmpty) {
    return 'peerhist_${m.messageId}';
  }
  return 'peerhist_${channelId}_$index';
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

/// Result of [PeerAgentClientService.syncAgentIncremental].
class PeerAgentIncrementalSyncResult {
  /// Channels linked/repaired by [PeerAgentClientService.syncSessions].
  final int sessionsLinked;

  /// Remote sessions whose history was attempted this round.
  final int dirtySessionCount;

  /// Sessions where [PeerAgentClientService.syncHistory] wrote at least one row.
  final int historySessionsWritten;

  /// Total messages upserted across all dirty sessions.
  final int totalMessagesWritten;

  /// Messages written into the prioritized (currently open) channel.
  final int currentChannelMessagesWritten;

  /// Whether the agent-level watermark was advanced.
  final bool watermarkAdvanced;

  const PeerAgentIncrementalSyncResult({
    this.sessionsLinked = 0,
    this.dirtySessionCount = 0,
    this.historySessionsWritten = 0,
    this.totalMessagesWritten = 0,
    this.currentChannelMessagesWritten = 0,
    this.watermarkAdvanced = false,
  });
}

class _PendingRequest {
  final String peerId;
  final void Function(String chunk)? onChunk;
  final void Function(Map<String, dynamic>)? onMetadata;
  final void Function(Map<String, dynamic>)? onActionConfirmation;
  final Completer<PeerChatResult> completer = Completer<PeerChatResult>();
  /// In-flight tool approvals not yet submitted by the user.
  int openApprovals = 0;
  /// Last moment this turn had zero open approvals (turn start, or when the
  /// last open approval was submitted). The chat watchdog measures from here
  /// so the time the user spends reading an approval card never counts
  /// against the 300s turn budget.
  DateTime noOpenApprovalsSince = DateTime.now();
  /// agent_done payload held until [openApprovals] reaches zero.
  Map<String, dynamic>? bufferedDone;
  _PendingRequest(
    this.peerId,
    this.onChunk,
    this.onActionConfirmation, {
    this.onMetadata,
  });
}

class _PendingFilePush {
  final Completer<void> begin = Completer<void>();
  final Completer<void> end = Completer<void>();
}

class PeerAgentClientService {
  PeerAgentClientService._();
  static final PeerAgentClientService instance = PeerAgentClientService._();

  static const _tag = 'PeerAgentClient';

  /// Upper bound for a single peer agent chat request. Aligned with the ACP
  /// group task timeout (300s) so a peer that stays connected but never
  /// answers cannot hang a group orchestration forever.
  ///
  /// Only runs while no approval card is open — see [approvalWaitHardCap].
  static const Duration chatTimeout = Duration(seconds: 300);

  /// Hard upper bound for a turn even while an approval is open. The bridge
  /// denies an unanswered approval after 20 min (agent-hub
  /// APPROVAL_TIMEOUT_MS), which also ends the turn — waiting past 25 min
  /// means the verdict path is gone for good.
  static const Duration approvalWaitHardCap = Duration(minutes: 25);

  final _log = LoggerService();
  final _uuid = const Uuid();

  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  StreamSubscription<void>? _peerListSub;
  bool _running = false;

  /// 进行中的请求（requestId → pending）。
  final Map<String, _PendingRequest> _pending = {};

  /// In-flight peer file pushes (fileId → begin/end completers).
  final Map<String, _PendingFilePush> _pendingFilePushes = {};

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

  /// Maps hub approval_id → agent_chat request_id for deferred completion.
  final Map<String, String> _approvalToRequest = {};

  /// Approvals that arrived after agent_done already cleared `_pending`.
  /// Kept briefly so a late UI path can still surface / submit them.
  final Map<String, Map<String, dynamic>> _orphanedApprovals = {};

  /// requestId → owning agent, retained briefly after a turn finishes so an
  /// approval that outlives its sendChat request (e.g. the hub restarted
  /// mid-approval and re-sent it after reconnect) can still be routed to the
  /// right chat screen. Bounded — oldest entries are evicted.
  final Map<String, ({String peerId, String remoteAgentId})> _requestAgents = {};

  /// Orphan approvals republished for open chat screens. Carries the
  /// actionConfirmation payload plus `peer_id` / `remote_agent_id`.
  final _orphanApprovalController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get orphanApprovalEvents =>
      _orphanApprovalController.stream;

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
    _approvalToRequest.clear();
    _orphanedApprovals.clear();
    _requestAgents.clear();
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
    _approvalToRequest.clear();
  }

  // ── 发送（消费方 → 提供方） ────────────────────────────────────────────

  /// Push [attachment] bytes to the peer host under [remoteAgentId]'s directory.
  ///
  /// Returns the `file_id` acknowledged by the host.
  Future<String> pushFile({
    required String peerId,
    required String remoteAgentId,
    required AttachmentData attachment,
  }) async {
    if (attachment.exceedsSizeLimit) {
      throw Exception(
        '附件过大（上限 ${AttachmentData.maxSizeBytes ~/ (1024 * 1024)}MB）: '
        '${attachment.fileName}',
      );
    }
    final fileId = _uuid.v4().replaceAll('-', '').substring(0, 12);
    final pending = _PendingFilePush();
    _pendingFilePushes[fileId] = pending;

    void clearPending() => _pendingFilePushes.remove(fileId);

    final beginSent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_file_begin',
      'agent_id': remoteAgentId,
      'file_id': fileId,
      'file_name': attachment.fileName,
      'mime_type': attachment.mimeType,
      'file_type': attachment.semanticType,
      'size': attachment.sizeBytes,
    });
    if (!beginSent) {
      clearPending();
      throw Exception('配对设备未连接，无法推送附件');
    }

    try {
      await pending.begin.future.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      clearPending();
      throw Exception(
        '对端未响应附件推送（${attachment.fileName}）。'
        '请确认对端已更新并重启 agent-bridge / App',
      );
    } catch (e) {
      clearPending();
      rethrow;
    }

    final bytes = attachment.bytes;
    const chunkSize = AttachmentData.peerChunkBytes;
    var index = 0;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize < bytes.length)
          ? offset + chunkSize
          : bytes.length;
      final slice = bytes.sublist(offset, end);
      final chunkSent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_file_chunk',
        'file_id': fileId,
        'index': index,
        'data': base64Encode(slice),
      });
      if (!chunkSent) {
        clearPending();
        throw Exception('推送附件分片失败（连接中断）');
      }
      index++;
    }

    final endSent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_file_end',
      'file_id': fileId,
      'chunk_count': index,
    });
    if (!endSent) {
      clearPending();
      throw Exception('推送附件结束帧失败（连接中断）');
    }

    try {
      await pending.end.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      clearPending();
      throw Exception('推送附件超时: ${attachment.fileName}');
    } catch (e) {
      clearPending();
      rethrow;
    }
    clearPending();
    return fileId;
  }

  /// 通过 P2P 通道把消息发给对端的本地 agent，流式接收回复。
  ///
  /// 对端未连接时立即抛错。[cancelToken] 触发时会向对端发送 `agent_cancel`。
  /// Attachments are pushed via [pushFile] first; `agent_chat` only carries
  /// `file_id` refs (no base64 payload).
  Future<PeerChatResult> sendChat({
    required String peerId,
    required String remoteAgentId,
    required String message,
    String? sessionId,
    List<AttachmentData>? attachments,
    void Function(String chunk)? onChunk,
    void Function(Map<String, dynamic>)? onMetadata,
    void Function(Map<String, dynamic>)? onActionConfirmation,
    ACPCancellationToken? cancelToken,
  }) async {
    List<Map<String, dynamic>>? attachmentRefs;
    if (attachments != null && attachments.isNotEmpty) {
      attachmentRefs = <Map<String, dynamic>>[];
      for (final att in attachments) {
        if (att.exceedsSizeLimit) {
          throw Exception(
            '附件过大（上限 ${AttachmentData.maxSizeBytes ~/ (1024 * 1024)}MB）: '
            '${att.fileName}',
          );
        }
        final fileId = await pushFile(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          attachment: att,
        );
        attachmentRefs.add(att.toPeerRefJson(fileId));
      }
    }

    final requestId = _uuid.v4();
    final pending = _PendingRequest(
      peerId,
      onChunk,
      onActionConfirmation,
      onMetadata: onMetadata,
    );
    _pending[requestId] = pending;
    _requestAgents[requestId] = (peerId: peerId, remoteAgentId: remoteAgentId);
    if (_requestAgents.length > 200) {
      _requestAgents.remove(_requestAgents.keys.first);
    }

    cancelToken?.addOnCancelled(() {
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_cancel',
        'request_id': requestId,
      }));
      final p = _pending.remove(requestId);
      if (p != null && !p.completer.isCompleted) {
        p.completer.complete(PeerChatResult(content: '[Stopped]'));
      }
    });

    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_chat',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'message': message,
      // 把本端会话 id 透传给对端，使对端按会话隔离历史：本端「新开会话」
      // 在对端也得到一条干净、无历史的新会话。
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (attachmentRefs != null) 'attachments': attachmentRefs,
    });

    if (!sent) {
      _pending.remove(requestId);
      throw Exception('配对设备未连接，无法发送');
    }

    return _awaitTurnCompletion(requestId, pending, peerId);
  }

  /// Await the turn with an approval-aware watchdog.
  ///
  /// [chatTimeout] only runs while no approval card is open: the time the
  /// user spends reading a tool approval must not count against the turn —
  /// the bridge allows 20 minutes per approval. Firing the timeout mid-
  /// approval cancels the remote turn and strands the verdict, which looks
  /// exactly like "approved but stuck". [approvalWaitHardCap] bounds even
  /// the approval-waiting state in case the bridge's denial never arrives.
  Future<PeerChatResult> _awaitTurnCompletion(
    String requestId,
    _PendingRequest pending,
    String peerId,
  ) async {
    final startedAt = DateTime.now();
    final watchdog = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (pending.completer.isCompleted) {
        timer.cancel();
        return;
      }
      final now = DateTime.now();
      final idleTooLong = pending.openApprovals == 0 &&
          now.difference(pending.noOpenApprovalsSince) > chatTimeout;
      final hardCapHit = now.difference(startedAt) > approvalWaitHardCap;
      if (idleTooLong || hardCapHit) {
        timer.cancel();
        _timeoutRequest(
          requestId,
          peerId,
          duringApproval: pending.openApprovals > 0,
        );
      }
    });
    try {
      return await pending.completer.future;
    } finally {
      watchdog.cancel();
    }
  }

  /// Shared timeout path: drop the pending entry so late frames are ignored,
  /// tell the remote to abort so its side does not keep running, and fail
  /// the future.
  void _timeoutRequest(
    String requestId,
    String peerId, {
    required bool duringApproval,
  }) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    unawaited(PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_cancel',
      'request_id': requestId,
    }));
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    _log.warning(
      'chat timeout requestId=$requestId duringApproval=$duringApproval '
      'openApprovals=${p.openApprovals}',
      tag: 'PeerApproval',
    );
    p.completer.completeError(
      TimeoutException(
        duringApproval
            ? '审批等待超时，请重新发送消息'
            : '对端 agent 响应超时（${chatTimeout.inSeconds}s）',
        chatTimeout,
      ),
    );
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
      case 'agent_metadata':
        _onMetadata(event.data);
        break;
      case 'agent_done':
        _onDone(event.data);
        break;
      case 'agent_error':
        _onError(event.data);
        break;
      case 'agent_approval_req':
        _onApprovalReq(event.peerId, event.data);
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
      case 'agent_file_ack':
        _onFileAck(event.data);
        break;
      case 'agent_file_error':
        _onFileError(event.data);
        break;
    }
  }

  void _onFileAck(Map<String, dynamic> data) {
    final fileId = data['file_id'] as String?;
    if (fileId == null) return;
    final pending = _pendingFilePushes[fileId];
    if (pending == null) return;
    final ok = data['ok'] != false;
    final stage = data['stage'] as String? ?? 'end';
    final error = data['error'] as String? ?? '附件推送被对端拒绝';

    void fail(Completer<void> c) {
      if (!c.isCompleted) c.completeError(Exception(error));
    }

    void succeed(Completer<void> c) {
      if (!c.isCompleted) c.complete();
    }

    if (stage == 'begin') {
      if (ok) {
        succeed(pending.begin);
      } else {
        fail(pending.begin);
        fail(pending.end);
        _pendingFilePushes.remove(fileId);
      }
      return;
    }

    // stage == end (or legacy ack without stage)
    if (ok) {
      // If begin was skipped somehow, still unblock it.
      succeed(pending.begin);
      succeed(pending.end);
    } else {
      fail(pending.begin);
      fail(pending.end);
      _pendingFilePushes.remove(fileId);
    }
  }

  void _onFileError(Map<String, dynamic> data) {
    final fileId = data['file_id'] as String?;
    if (fileId == null) return;
    final pending = _pendingFilePushes.remove(fileId);
    if (pending == null) return;
    final err = Exception(data['message'] as String? ?? '附件推送失败');
    if (!pending.begin.isCompleted) pending.begin.completeError(err);
    if (!pending.end.isCompleted) pending.end.completeError(err);
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

  /// Agent-level watermark for peer history incremental sync.
  Future<DateTime?> getLastHistorySyncAt(String localAgentId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(peerHistoryLastSyncPrefsKey(localAgentId));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Persist the agent-level history sync watermark (UTC ISO-8601).
  Future<void> setLastHistorySyncAt(String localAgentId, DateTime at) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      peerHistoryLastSyncPrefsKey(localAgentId),
      at.toUtc().toIso8601String(),
    );
  }

  /// Incrementally sync all dirty remote sessions for a peer agent.
  ///
  /// 1. Enumerate remote sessions and ensure local channel shells exist.
  /// 2. Select dirty sessions via [selectDirtySessions] (watermark + overlap).
  /// 3. Pull history for each dirty session (prioritized channel first).
  /// 4. Advance the watermark to [syncStartedAt] only if every attempt finishes
  ///    without throwing.
  ///
  /// [onPrioritizedChannelDone] is invoked after the prioritized channel's
  /// history attempt (even when 0 messages were written) so the UI can stop
  /// its spinner and reload.
  Future<PeerAgentIncrementalSyncResult> syncAgentIncremental({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String agentName,
    required String userId,
    required String userName,
    String? prioritizeChannelId,
    Future<void> Function(int written)? onPrioritizedChannelDone,
  }) async {
    final syncStartedAt = DateTime.now().toUtc();
    final sessions = await fetchSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    if (sessions.isEmpty) {
      return const PeerAgentIncrementalSyncResult();
    }

    final linked = await syncSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId,
      userId: userId,
      sessions: sessions,
    );

    final lastSyncAt = await getLastHistorySyncAt(localAgentId);
    final prioritizeSessionId = prioritizeChannelId != null
        ? remoteSessionIdFromChannelId(prioritizeChannelId)
        : null;
    final dirty = selectDirtySessions(
      sessions,
      lastSyncAt: lastSyncAt,
      prioritizeSessionId: prioritizeSessionId,
    );

    var historySessionsWritten = 0;
    var totalMessagesWritten = 0;
    var currentChannelMessagesWritten = 0;
    var prioritizedDone = false;

    try {
      for (final session in dirty) {
        final channelId = syncedPeerChannelId(session.sessionId);
        final written = await syncHistory(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          localAgentId: localAgentId,
          agentName: agentName,
          channelId: channelId,
          userId: userId,
          userName: userName,
          sessionUpdatedAt: session.updatedAt,
        );
        if (written > 0) {
          historySessionsWritten++;
          totalMessagesWritten += written;
        }
        if (prioritizeSessionId != null &&
            session.sessionId == prioritizeSessionId) {
          currentChannelMessagesWritten = written;
          prioritizedDone = true;
          if (onPrioritizedChannelDone != null) {
            await onPrioritizedChannelDone(written);
          }
        }
      }
    } catch (e, st) {
      _log.warning(
        'Incremental sync aborted for $localAgentId: $e\n$st',
        tag: _tag,
        error: e,
      );
      if (!prioritizedDone &&
          prioritizeSessionId != null &&
          onPrioritizedChannelDone != null) {
        await onPrioritizedChannelDone(currentChannelMessagesWritten);
      }
      return PeerAgentIncrementalSyncResult(
        sessionsLinked: linked,
        dirtySessionCount: dirty.length,
        historySessionsWritten: historySessionsWritten,
        totalMessagesWritten: totalMessagesWritten,
        currentChannelMessagesWritten: currentChannelMessagesWritten,
        watermarkAdvanced: false,
      );
    }

    // Prioritized session was not dirty — still notify so UI can clear spinner.
    if (!prioritizedDone &&
        prioritizeSessionId != null &&
        onPrioritizedChannelDone != null) {
      await onPrioritizedChannelDone(0);
    }

    await setLastHistorySyncAt(localAgentId, syncStartedAt);
    _log.info(
      'Incremental sync for $localAgentId: '
      '${dirty.length} dirty / ${sessions.length} sessions, '
      '$totalMessagesWritten message(s) written',
      tag: _tag,
    );
    return PeerAgentIncrementalSyncResult(
      sessionsLinked: linked,
      dirtySessionCount: dirty.length,
      historySessionsWritten: historySessionsWritten,
      totalMessagesWritten: totalMessagesWritten,
      currentChannelMessagesWritten: currentChannelMessagesWritten,
      watermarkAdvanced: true,
    );
  }

  /// Pull a synced session's transcript from the remote and mirror it locally.
  ///
  /// Fetches the remote transcript; if it differs from what's stored locally
  /// (content or resolved send times), upserts by stable `peerhist_*` ids and
  /// removes local rows that are no longer present remotely. If the fetch is
  /// empty (agent can't replay / timeout), local messages are kept untouched.
  /// Returns the number of messages written, or 0 when nothing changed / local
  /// was kept.
  Future<int> syncHistory({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String agentName,
    required String channelId,
    required String userId,
    required String userName,
    DateTime? sessionUpdatedAt,
  }) async {
    final remoteSessionId = remoteSessionIdFromChannelId(channelId);
    if (remoteSessionId == null) return 0;

    final history = await fetchHistory(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: remoteSessionId,
    );
    if (history.isEmpty) return 0;

    final existing = await _db.getChannelMessages(channelId, limit: 2000);
    final existingAsc = existing.reversed.toList();
    final existingById = <String, DateTime>{};
    for (final row in existingAsc) {
      final id = row['id'] as String?;
      final rawAt = row['created_at'] as String?;
      if (id == null || rawAt == null) continue;
      final at = DateTime.tryParse(rawAt);
      if (at != null) existingById[id] = at;
    }

    final createdAts = assignPeerHistoryTimestamps(
      history,
      existingById: existingById,
      sessionUpdatedAt: sessionUpdatedAt,
      idFor: (m, i) => peerHistoryMessageId(m, channelId, i),
    );

    // Skip the rewrite (and UI flicker) when local already matches remote
    // content and the resolved send times.
    if (existingAsc.length == history.length) {
      var identical = true;
      for (var i = 0; i < history.length; i++) {
        final row = existingAsc[i];
        final role = (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
        if (role != history[i].role ||
            (row['content'] as String? ?? '') != history[i].content) {
          identical = false;
          break;
        }
        final localAt = DateTime.tryParse(row['created_at'] as String? ?? '');
        if (localAt == null ||
            localAt.toUtc().millisecondsSinceEpoch !=
                createdAts[i].toUtc().millisecondsSinceEpoch) {
          identical = false;
          break;
        }
      }
      if (identical) return 0;
    }

    final remoteIds = <String>{};
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isUser = m.role == 'user';
      final msgId = peerHistoryMessageId(m, channelId, i);
      remoteIds.add(msgId);
      await _db.createMessage(
        id: msgId,
        channelId: channelId,
        senderId: isUser ? userId : localAgentId,
        senderType: isUser ? 'user' : 'agent',
        senderName: isUser ? userName : agentName,
        content: m.content,
        createdAt: createdAts[i],
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    // Drop local rows that are no longer in the remote transcript so the
    // channel stays pull-authoritative without a full delete+rewrite wipe.
    for (final row in existingAsc) {
      final id = row['id'] as String?;
      if (id != null && !remoteIds.contains(id)) {
        await _db.deleteMessage(id);
      }
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
  void _onApprovalReq(String peerId, Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) {
      _log.warning('agent_approval_req: missing request_id', tag: 'PeerApproval');
      return;
    }
    final rawApprovalId = data['approval_id'] as String?;
    var approvalId = PeerApprovalPayload.normalizeApprovalId(
      rawApprovalId,
      requestId,
    );
    final actions = data['actions'] ?? const [];
    final pending = _pending[requestId];
    final hasCallback = pending?.onActionConfirmation != null;
    _log.info(
      'agent_approval_req: approvalId=$approvalId requestId=$requestId '
      'pendingRequest=${pending != null} hasCallback=$hasCallback '
      'actions=${actions is List ? actions.length : 0} '
      'toolKind=${data['tool_kind']} toolCallId=${data['tool_call_id']}',
      tag: 'PeerApproval',
    );

    if (rawApprovalId == null || rawApprovalId.isEmpty) {
      _log.warning(
        'agent_approval_req: empty approval_id — using synthetic id=$approvalId',
        tag: 'PeerApproval',
      );
    }

    if (pending == null) {
      // agent_done may have already completed the request (hub/client race).
      // Keep a deferred slot so a late UI path can still submit the verdict.
      _log.warning(
        'agent_approval_req: no pending request for requestId=$requestId — '
        'buffering as orphan approvalId=$approvalId',
        tag: 'PeerApproval',
      );
      _orphanedApprovals[approvalId] = Map<String, dynamic>.from(data);
    } else {
      pending.openApprovals++;
      _approvalToRequest[approvalId] = requestId;
      if (!hasCallback) {
        _log.warning(
          'agent_approval_req: pending request has null onActionConfirmation '
          'for requestId=$requestId — will still forward if callback appears',
          tag: 'PeerApproval',
        );
      }
    }

    final rawActions = actions is List ? List<dynamic>.from(actions) : <dynamic>[];
    final effectiveActions = PeerApprovalPayload.effectiveActions(rawActions);
    final actionData = PeerApprovalPayload.buildActionConfirmationData(
      data: data,
      approvalId: approvalId,
      actions: effectiveActions,
    );
    if (pending == null) {
      // Orphan: no live sendChat turn owns this approval (hub restarted
      // mid-approval and re-sent after reconnect, or agent_done raced ahead).
      // Republish so an open chat screen can still render the card — the tap
      // reaches submitApproval, which only needs the approval_id.
      final owner = _requestAgents[requestId];
      if (owner != null && !_orphanApprovalController.isClosed) {
        _orphanApprovalController.add({
          ...actionData,
          'peer_id': peerId,
          'remote_agent_id': owner.remoteAgentId,
          // No live turn owns this approval — the UI must not show a spinner.
          'orphan': true,
        });
      }
    }
    pending?.onActionConfirmation?.call(actionData);
    _log.debug(
      'agent_approval_req: forwarded to UI confirmationId=$approvalId '
      'delivered=${pending?.onActionConfirmation != null}',
      tag: 'PeerApproval',
    );
  }

  /// Submit the user's tool-call decision back to the hub.
  ///
  /// Send `agent_approval_resp` **before** decrementing [openApprovals] /
  /// completing a buffered `agent_done`. Completing first can finish
  /// [sendChat] (and clear streaming UI) while the verdict is still in
  /// flight; subsequent chunks then have nowhere to land.
  ///
  /// If the peer is offline the verdict is not dropped from the local gate —
  /// [openApprovals] stays elevated so a later reconnect / retry can still
  /// unblock, and we throw so the UI can surface the failure.
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
    final payload = <String, dynamic>{
      'type': 'agent_approval_resp',
      'approval_id': approvalId,
      'selected_action_id': selectedActionId,
      if (selectedActionLabel != null && selectedActionLabel.isNotEmpty)
        'selected_action_label': selectedActionLabel,
    };

    // Retry briefly — a single dropped frame after Allow leaves Cursor hung
    // on [pending] for the rest of the turn.
    var sent = false;
    Object? lastErr;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
        if (sent) break;
        lastErr = 'peer not connected';
      } catch (e) {
        lastErr = e;
      }
      if (attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      }
    }
    if (!sent) {
      _log.warning(
        'submitApproval FAILED approvalId=$approvalId err=$lastErr — '
        'keeping openApprovals gate so the turn does not finish without a verdict',
        tag: 'PeerApproval',
      );
      throw Exception('审核结果发送失败，请确认配对设备在线后重试');
    }

    final requestId = _approvalToRequest.remove(approvalId);
    if (requestId != null) {
      final pending = _pending[requestId];
      if (pending != null && pending.openApprovals > 0) {
        pending.openApprovals--;
        if (pending.openApprovals == 0) {
          // Verdict is on the wire — the plain chat clock runs from here.
          pending.noOpenApprovalsSince = DateTime.now();
        }
      }
      // Async-confirmation agents may have buffered agent_done while the
      // approval was open — complete now that the verdict is on the wire.
      _tryCompleteBufferedDone(requestId);
    }
  }

  void _onChunk(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    final content = data['content'] as String? ?? '';
    if (requestId == null) return;
    _pending[requestId]?.onChunk?.call(content);
  }

  void _onMetadata(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final raw = data['metadata'];
    final metadata = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    if (metadata.isEmpty) return;
    _pending[requestId]?.onMetadata?.call(metadata);
  }

  void _finishPending(String requestId, Map<String, dynamic> data) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    p.completer.complete(PeerChatResult(
      content: data['content'] as String? ?? '',
      metadata: (data['metadata'] as Map?)?.cast<String, dynamic>(),
    ));
  }

  void _tryCompleteBufferedDone(String requestId) {
    final p = _pending[requestId];
    if (p == null || p.openApprovals > 0 || p.bufferedDone == null) return;
    _finishPending(requestId, p.bufferedDone!);
  }

  void _onDone(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted) return;
    if (p.openApprovals > 0) {
      p.bufferedDone = Map<String, dynamic>.from(data);
      _log.info(
        'agent_done buffered for requestId=$requestId '
        'openApprovals=${p.openApprovals}',
        tag: 'PeerApproval',
      );
      return;
    }
    _finishPending(requestId, data);
  }

  void _onError(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    p.completer.completeError(
      Exception(data['message'] as String? ?? 'Peer agent error'),
    );
  }

  // ── agent 列表注入 / 清理 ──────────────────────────────────────────────

  void _onConnectionEvent(PeerConnectionEvent event) {
    if (event.type == PeerConnectionEventType.connected) {
      _requestAgentList(event.peerId);
    } else if (event.type == PeerConnectionEventType.disconnected) {
      _failPendingForPeer(event.peerId);
      unawaited(_markPeerAgentsOffline(event.peerId));
    }
  }

  /// Abort in-flight sendChat turns when the peer drops mid-approval / mid-
  /// stream. Without this, openApprovals + a missing agent_done leave the UI
  /// spinner hung until the user force-stops.
  void _failPendingForPeer(String peerId) {
    final toFail = <String>[];
    for (final entry in _pending.entries) {
      if (entry.value.peerId != peerId) continue;
      if (entry.value.completer.isCompleted) continue;
      toFail.add(entry.key);
    }
    for (final requestId in toFail) {
      final p = _pending.remove(requestId);
      if (p == null || p.completer.isCompleted) continue;
      for (final entry in _approvalToRequest.entries.toList()) {
        if (entry.value == requestId) {
          _approvalToRequest.remove(entry.key);
        }
      }
      _log.warning(
        'peer disconnected — failing in-flight requestId=$requestId '
        'openApprovals=${p.openApprovals}',
        tag: 'PeerApproval',
      );
      p.completer.completeError(
        Exception('配对设备已断开，对话中断'),
      );
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
        final supportedModalities = (raw['supported_modalities'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
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
            if (supportedModalities.isNotEmpty)
              'supported_modalities': supportedModalities,
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

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
import '../../services/app_lifecycle_service.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../service_locator.dart' show getIt;
import '../../utils/engine_avatars.dart';
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer_approval_payload.dart';
import 'peer_agent_ids.dart';
import 'peer_connection_manager.dart';
import 'peer_inflight_turn.dart';
import 'peer_storage_service.dart';
import 'peer_turn_resume.dart';

export 'peer_agent_ids.dart';
export 'peer_inflight_turn.dart' show PeerTurnInFlightException;

/// Resolve which local agent row id to use for a hub remote agent id.
Future<String> resolvePeerAgentRowId(
  LocalDatabaseService db,
  String peerId,
  String remoteAgentId,
) async {
  final legacy = legacyPeerAgentLocalId(peerId, remoteAgentId);
  final byLegacy = await db.getRemoteAgentById(legacy);
  final byRemote = await db.getRemoteAgentById(remoteAgentId);
  return decidePeerAgentRowId(
    peerId: peerId,
    remoteAgentId: remoteAgentId,
    existingByRemoteId: byRemote,
    existingByLegacyId: byLegacy,
  );
}

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

/// Remote session ids already represented by local peer-agent channels.
///
/// Includes both `psess_<remoteSessionId>` shells and legacy live channels whose
/// id was sent to the peer as `session_id` (typically `dm_*` / timestamped ids).
Set<String> collectLocalBoundRemoteSessionIds(
  Iterable<String> localChannelIds,
  Set<String> remoteSessionIds,
) {
  final bound = <String>{};
  for (final id in localChannelIds) {
    final fromPsess = remoteSessionIdFromChannelId(id);
    if (fromPsess != null) {
      bound.add(fromPsess);
    } else if (remoteSessionIds.contains(id)) {
      bound.add(id);
    }
  }
  return bound;
}

/// Map a local chat channel to the peer-visible session id, when known.
String? peerRemoteSessionIdForLocalChannel(
  String? localChannelId, {
  Set<String>? knownRemoteSessionIds,
}) {
  if (localChannelId == null || localChannelId.isEmpty) return null;
  final fromPsess = remoteSessionIdFromChannelId(localChannelId);
  if (fromPsess != null) return fromPsess;
  if (knownRemoteSessionIds != null &&
      knownRemoteSessionIds.contains(localChannelId)) {
    return localChannelId;
  }
  return null;
}

/// Choose the local channel id to mirror [remoteSessionId].
///
/// Prefer an existing live channel whose id equals the remote session id so
/// incremental sync does not fork a duplicate `psess_` shell. Otherwise reuse
/// an existing `psess_` channel or default to creating one.
String resolveLocalPeerChannelId(
  String remoteSessionId, {
  required bool psessExists,
  required bool legacyExists,
}) {
  if (legacyExists) return remoteSessionId;
  if (psessExists) return syncedPeerChannelId(remoteSessionId);
  return syncedPeerChannelId(remoteSessionId);
}

/// Whether [localChannelId] and [remoteSessionId] refer to the same peer session.
bool localChannelBindsRemoteSession(
  String localChannelId,
  String remoteSessionId,
) {
  final fromPsess = remoteSessionIdFromChannelId(localChannelId);
  if (fromPsess != null) return fromPsess == remoteSessionId;
  return localChannelId == remoteSessionId;
}

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
  /// P2P `agent_chat` request id — correlates frames, approvals, and traces.
  final String? requestId;
  PeerChatResult({
    required this.content,
    this.metadata,
    this.requestId,
  });
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

  /// Pre-split progress section (thinking/tools/plan) reconstructed by
  /// agent-bridge from the engine transcript. Rendered via the same
  /// `metadata.progress_content` collapsible the live stream uses, so a
  /// synced bubble looks like the live one.
  final String? progressContent;
  final String? progressTitle;
  final bool? progressAutoCollapse;

  PeerHistoryMessage({
    required this.role,
    required this.content,
    this.messageId,
    this.createdAt,
    this.progressContent,
    this.progressTitle,
    this.progressAutoCollapse,
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
    final rawProgress = json['progress_content'] as String?;
    return PeerHistoryMessage(
      role: role,
      content: content,
      messageId: json['message_id'] as String?,
      createdAt: createdAt,
      progressContent:
          (rawProgress?.isNotEmpty ?? false) ? rawProgress : null,
      progressTitle: json['progress_title'] as String?,
      progressAutoCollapse: json['progress_auto_collapse'] as bool?,
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

/// `progress_content` stored in a local message row's metadata JSON ('' if none).
String _rowProgressContent(Map<String, dynamic> row) {
  final raw = row['metadata'] as String?;
  if (raw == null || raw.isEmpty) return '';
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['progress_content'] is String) {
      return decoded['progress_content'] as String;
    }
  } catch (_) {
    // Treat undecodable metadata as "no progress".
  }
  return '';
}

/// Metadata to persist for a synced history message: the reconstructed
/// progress section (thinking/tools/plan) in the same shape the live stream
/// produces, so the bubble renders the identical collapsible block.
/// Returns null when the message carries no progress.
Map<String, dynamic>? peerHistoryMessageMetadata(PeerHistoryMessage m) {
  final progress = m.progressContent;
  if (progress == null || progress.isEmpty) return null;
  return {
    'progress_content': progress,
    'collapsible': true,
    'collapsible_title': m.progressTitle ?? 'Details',
    'auto_collapse': m.progressAutoCollapse ?? true,
  };
}

/// When re-upserting a synced history row, keep the prior read bit if the
/// turn content is unchanged. [ConflictAlgorithm.replace] would otherwise reset
/// `is_read` to 0 and resurrect unread badges for locally-created sessions.
int preservedReadStateForHistorySync({
  required PeerHistoryMessage remote,
  Map<String, dynamic>? existingRow,
}) {
  if (existingRow == null) return 0;
  final prevRole =
      (existingRow['sender_type'] as String?) == 'user' ? 'user' : 'agent';
  if (prevRole != remote.role) return 0;
  if ((existingRow['content'] as String? ?? '') != remote.content) return 0;
  return existingRow['is_read'] as int? ?? 0;
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

/// One upstream session-mode option from `agent_modes_resp`.
class PeerAgentMode {
  final String value;
  final String displayName;
  final String description;

  PeerAgentMode({
    required this.value,
    required this.displayName,
    this.description = '',
  });

  static PeerAgentMode? fromJson(Map<String, dynamic> json) {
    final rawValue = json['value'] ?? json['id'];
    final value = rawValue is String ? rawValue.trim() : '';
    if (value.isEmpty) return null;
    final display = (json['display_name'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    return PeerAgentMode(
      value: value,
      displayName: (display != null && display.isNotEmpty)
          ? display
          : (name != null && name.isNotEmpty)
              ? name
              : value,
      description: (json['description'] as String?) ?? '',
    );
  }
}

/// Upstream session-mode list + current selection (`agent_modes_resp`).
class PeerModesList {
  final List<PeerAgentMode> modes;
  final String? current;

  const PeerModesList({required this.modes, this.current});
}

/// Soul text + edit permission from `agent_soul_resp`.
class PeerSoulInfo {
  final String soul;
  final bool editable;

  const PeerSoulInfo({required this.soul, required this.editable});
}

/// One hub instance as returned by `agent_manage_resp`.
class PeerAgentManageEntry {
  final String id;
  final String name;
  final String engine;
  final bool running;
  final bool enabled;
  final bool manageable;

  const PeerAgentManageEntry({
    required this.id,
    required this.name,
    this.engine = '',
    required this.running,
    required this.enabled,
    required this.manageable,
  });

  factory PeerAgentManageEntry.fromJson(Map<String, dynamic> json) {
    return PeerAgentManageEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      engine: json['engine'] as String? ?? '',
      running: json['running'] == true,
      enabled: json['enabled'] != false,
      manageable: json['manageable'] == true,
    );
  }
}

class PeerAgentManageResult {
  final bool ok;
  final String? error;
  final List<PeerAgentManageEntry> agents;
  final bool unsupported;

  const PeerAgentManageResult({
    required this.ok,
    this.error,
    this.agents = const [],
    this.unsupported = false,
  });
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
  final String remoteAgentId;
  final String localAgentId;
  final String channelId;
  final String sessionId;
  final String userMessageId;
  final String userId;
  final String userName;
  final String agentName;
  final int startedAtMs;
  void Function(String chunk)? onChunk;
  void Function(Map<String, dynamic>)? onMetadata;
  void Function(Map<String, dynamic>)? onActionConfirmation;
  final Completer<PeerChatResult> completer = Completer<PeerChatResult>();
  /// In-flight tool approvals not yet submitted by the user.
  int openApprovals = 0;
  /// Last moment this turn had agent output or entered a non-idle state (turn
  /// start, each chunk/metadata, when the last open approval was submitted, or
  /// after a successful turn resume). The chat watchdog measures idle from
  /// here so streaming output and time spent reading an approval card never
  /// count against the 300s turn budget.
  DateTime idleSince = DateTime.now();
  /// agent_done payload held until [openApprovals] reaches zero.
  Map<String, dynamic>? bufferedDone;
  /// 已接收 chunk 内容的累计长度（UTF-16 码元，与 hub 的 accumulated 对齐）。
  /// resume_req 的 known_content_length 即取此值。
  int receivedLength = 0;
  /// Answer text (progress stripped) for UI seed after a process restart.
  String answerContent = '';
  /// 非 null 表示该 turn 因 peer 断连而挂起，等待重连续传。
  DateTime? suspendedSince;
  /// 是否已发出 resume_req 且尚未收到应答（防止重复发送）。
  bool resumeInFlight = false;
  /// 发出 resume_req 时的 receivedLength 基准，用于 delta 去重（drop-prefix）。
  int? resumeBaseLength;
  _PendingRequest({
    required this.peerId,
    required this.remoteAgentId,
    this.localAgentId = '',
    this.channelId = '',
    this.sessionId = '',
    this.userMessageId = '',
    this.userId = '',
    this.userName = '',
    this.agentName = '',
    int? startedAtMs,
    this.onChunk,
    this.onActionConfirmation,
    this.onMetadata,
  }) : startedAtMs = startedAtMs ?? DateTime.now().millisecondsSinceEpoch;

  PeerInflightTurnRecord toRecord(String requestId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return PeerInflightTurnRecord(
      requestId: requestId,
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId,
      channelId: channelId,
      sessionId: sessionId,
      userMessageId: userMessageId,
      userId: userId,
      userName: userName,
      agentName: agentName,
      receivedLength: receivedLength,
      accumulatedContent: answerContent,
      startedAtMs: startedAtMs,
      updatedAtMs: now,
    );
  }
}

class _PendingFilePush {
  final Completer<void> begin = Completer<void>();
  /// Completes with host `store_uri` (may be null on legacy hosts).
  final Completer<String?> end = Completer<String?>();
}

class PeerAgentClientService {
  PeerAgentClientService._();
  static final PeerAgentClientService instance = PeerAgentClientService._();

  static const _tag = 'PeerAgentClient';

  /// Upper bound for a single peer agent chat request when the agent produces
  /// no output. Aligned with the ACP group task timeout (300s) so a peer that
  /// stays connected but never answers cannot hang a group orchestration
  /// forever. Each streaming chunk/metadata resets the idle clock; approval
  /// waits are excluded — see [approvalWaitHardCap].
  static const Duration chatTimeout = Duration(seconds: 300);

  /// Hard upper bound for a turn WHILE an approval is open. The bridge
  /// denies an unanswered approval after 20 min (agent-hub
  /// APPROVAL_TIMEOUT_MS), which also ends the turn — waiting past 25 min
  /// means the verdict path is gone for good. Turns without open approvals
  /// are not capped: a healthy long-running task may stream arbitrarily long
  /// (idle chunks reset the clock; a dead one trips [chatTimeout]).
  static const Duration approvalWaitHardCap = Duration(minutes: 25);

  /// 断连挂起（等待重连续传）的最长时长。挂起期间 idle 计时冻结（对端本来
  /// 就不可能有帧到达），超过该时长说明重连无望，判 turn 失败。
  /// 与 hub 侧 TURN_RESULT_TTL_MS（25min，终态结果的可回放窗口）对齐：
  /// app 先于 hub 放弃会让「hub 还留着结果、app 已判死」的窗口白白浪费。
  static const Duration suspendWaitHardCap = Duration(minutes: 25);

  /// resume_req 发出后对端无应答的容忍时长（旧版本 hub 不支持续传时
  /// 不会回复），超时按「对端不支持续传」失败，避免无限悬挂。
  static const Duration resumeResponseTimeout = Duration(seconds: 10);

  final _log = LoggerService();
  final _uuid = const Uuid();
  final _storage = PeerStorageService();
  final Map<String, Timer> _persistTimers = {};

  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  StreamSubscription<void>? _peerListSub;
  bool _running = false;
  /// False until [resumeHydratedTurns] so a `connected` event during
  /// bootstrap cannot complete a restored turn before ActiveTask handlers
  /// are attached.
  bool _handlersReadyForResume = false;

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

  /// Outstanding agent_modes_req per remote agent id.
  final Map<String, Completer<PeerModesList>> _pendingModes = {};

  /// Outstanding agent_modes_set_req per "agentId::mode" key.
  final Map<String, Completer<bool>> _pendingModeSet = {};

  /// Outstanding agent_soul_req per remote agent id.
  final Map<String, Completer<PeerSoulInfo?>> _pendingSoulGet = {};

  /// Outstanding agent_soul_set_req per remote agent id.
  final Map<String, Completer<bool>> _pendingSoulSet = {};

  /// Outstanding agent_manage_req keyed by request_id.
  final Map<String, Completer<PeerAgentManageResult>> _pendingManage = {};

  /// Maps hub approval_id → agent_chat request_id for deferred completion.
  final Map<String, String> _approvalToRequest = {};

  /// Approvals that arrived after agent_done already cleared `_pending`.
  /// Kept briefly so a late UI path can still surface / submit them.
  final Map<String, Map<String, dynamic>> _orphanedApprovals = {};

  /// 已成功提交的裁决（approvalId → 裁决内容）。hub 断连重连后会重发卡片；
  /// 若裁决其实已提交成功（只是 resp 没到达 hub），重发的卡片用这里存储的
  /// 裁决自动应答，不再计数、不再弹卡（E24）。
  /// 有界：超过 50 条时淘汰最旧。
  final Map<String, ({String actionId, String? label})> _submittedApprovals = {};

  /// 断连挂起期间用户本地取消的 turn（requestId → peerId）。
  /// 重连后对这些 requestId 补发 agent_cancel 而非 resume_req。
  /// 有界：超过 100 条时淘汰最旧。
  final Map<String, String> _cancelledWhileSuspended = {};

  /// 因断连而不可恢复地失败的 turn 所属的「peerId::remoteAgentId」。
  /// 这些 turn 的完整结果可能仍留在远端 transcript（hub 的 turn registry
  /// 或上游 agent 的会话历史）—— 重连后通过增量历史同步补回对话。
  /// 有界：超过 50 条时淘汰最旧。
  final Set<String> _reconcileNeeded = <String>{};

  /// 重连后需要做一次历史 reconcile 的「peerId::remoteAgentId」事件。
  /// 聊天页订阅后在 consent 允许时触发增量同步。
  final _reconcileController = StreamController<String>.broadcast();
  Stream<String> get reconcileRequests => _reconcileController.stream;

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

    // resumeAll 刷新连接前会征询此钩子：有在途 turn / 待决审批的连接必须保留，
    // 否则恢复前台（尤其桌面端，连接其实仍存活）会杀死整轮交互。
    PeerConnectionManager.instance.hasInFlightTurnForPeer = _hasInFlightTurnForPeer;

    // 对已连接的 peer 立即拉取一次列表，并清理已删除配对的残留 agent。
    await _reconcileDeletions();
    await _hydratePersistedTurns();
    if (_pending.isEmpty) {
      _handlersReadyForResume = true;
    }
    for (final peerId in PeerConnectionManager.instance.connectedPeerIds) {
      _requestAgentList(peerId);
    }
    _log.info('PeerAgentClientService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _handlersReadyForResume = false;
    PeerConnectionManager.instance.hasInFlightTurnForPeer = null;
    _controlSub?.cancel();
    _controlSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _peerListSub?.cancel();
    _peerListSub = null;
    for (final timer in _persistTimers.values) {
      timer.cancel();
    }
    _persistTimers.clear();
    for (final p in _pending.values) {
      if (!p.completer.isCompleted) {
        p.completer.completeError(StateError('PeerAgentClientService stopped'));
      }
    }
    _pending.clear();
    _approvalToRequest.clear();
    _orphanedApprovals.clear();
    _submittedApprovals.clear();
    _cancelledWhileSuspended.clear();
    _reconcileNeeded.clear();
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
    for (final c in _pendingManage.values) {
      if (!c.isCompleted) {
        c.complete(const PeerAgentManageResult(ok: false, error: 'stopped'));
      }
    }
    _pendingManage.clear();
    _approvalToRequest.clear();
  }

  /// In-flight turns restored from disk (and live ones). Used by ChatService
  /// to recreate [ActiveTask] so the UI can reattach after a process kill.
  List<PeerInflightTurnRecord> snapshotInflightTurns() {
    final out = <PeerInflightTurnRecord>[];
    for (final entry in _pending.entries) {
      final p = entry.value;
      if (p.completer.isCompleted) continue;
      out.add(p.toRecord(entry.key));
    }
    return out;
  }

  bool hasInflightForChannel(String channelId) {
    if (channelId.isEmpty) return false;
    for (final p in _pending.values) {
      if (!p.completer.isCompleted && p.channelId == channelId) return true;
    }
    return false;
  }

  bool hasInflightForSession({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) {
    final sid = sessionId ?? '';
    for (final p in _pending.values) {
      if (p.completer.isCompleted) continue;
      if (p.peerId != peerId || p.remoteAgentId != remoteAgentId) continue;
      if ((p.sessionId) == sid) return true;
    }
    return false;
  }

  /// Rebind UI/persistence callbacks on a hydrated turn after process restart.
  void attachPendingHandlers(
    String requestId, {
    void Function(String chunk)? onChunk,
    void Function(Map<String, dynamic>)? onMetadata,
    void Function(Map<String, dynamic>)? onActionConfirmation,
  }) {
    final p = _pending[requestId];
    if (p == null) return;
    p.onChunk = onChunk;
    p.onMetadata = onMetadata;
    p.onActionConfirmation = onActionConfirmation;
  }

  void noteInflightAnswer(String requestId, String answer) {
    final p = _pending[requestId];
    if (p == null) return;
    p.answerContent = answer;
    _schedulePersist(requestId);
  }

  Future<PeerChatResult> awaitPendingTurn(String requestId) {
    final p = _pending[requestId];
    if (p == null) {
      return Future.error(StateError('no pending turn $requestId'));
    }
    return _awaitTurnCompletion(requestId, p, p.peerId);
  }

  /// Resume hydrated turns on already-connected peers. Call AFTER ChatService
  /// has attached ActiveTask handlers so a fast `done` resume is not dropped.
  void resumeHydratedTurns() {
    _handlersReadyForResume = true;
    for (final peerId in PeerConnectionManager.instance.connectedPeerIds) {
      unawaited(_resumeSuspendedTurns(peerId));
    }
  }

  Future<void> _hydratePersistedTurns() async {
    List<PeerInflightTurnRecord> rows;
    try {
      rows = await _storage.loadAllInflightTurns();
    } catch (e) {
      _log.warning('load inflight turns failed: $e', tag: _tag, error: e);
      return;
    }
    final now = DateTime.now();
    for (final rec in rows) {
      if (rec.requestId.isEmpty) {
        await _storage.deleteInflightTurn(rec.requestId);
        continue;
      }
      if (isPeerInflightTurnExpired(rec, now: now)) {
        _log.info(
          'dropping expired inflight turn ${rec.requestId}',
          tag: _tag,
        );
        _requestAgents[rec.requestId] = (
          peerId: rec.peerId,
          remoteAgentId: rec.remoteAgentId,
        );
        _markReconcileNeeded(rec.requestId);
        await _storage.deleteInflightTurn(rec.requestId);
        continue;
      }
      if (_pending.containsKey(rec.requestId)) continue;
      final pending = _PendingRequest(
        peerId: rec.peerId,
        remoteAgentId: rec.remoteAgentId,
        localAgentId: rec.localAgentId,
        channelId: rec.channelId,
        sessionId: rec.sessionId,
        userMessageId: rec.userMessageId,
        userId: rec.userId,
        userName: rec.userName,
        agentName: rec.agentName,
        startedAtMs: rec.startedAtMs,
      );
      pending.receivedLength = rec.receivedLength;
      pending.answerContent = rec.accumulatedContent;
      pending.suspendedSince =
          DateTime.fromMillisecondsSinceEpoch(rec.updatedAtMs);
      _pending[rec.requestId] = pending;
      _requestAgents[rec.requestId] = (
        peerId: rec.peerId,
        remoteAgentId: rec.remoteAgentId,
      );
      _log.info(
        'hydrated inflight turn ${rec.requestId} channel=${rec.channelId} '
        'known=${rec.receivedLength}',
        tag: _tag,
      );
    }
  }

  void _schedulePersist(String requestId) {
    _persistTimers[requestId]?.cancel();
    _persistTimers[requestId] = Timer(const Duration(seconds: 1), () {
      _persistTimers.remove(requestId);
      unawaited(_persistTurnNow(requestId));
    });
  }

  Future<void> _persistTurnNow(String requestId) async {
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted) return;
    if (p.channelId.isEmpty && p.localAgentId.isEmpty) return;
    try {
      await _storage.upsertInflightTurn(p.toRecord(requestId));
    } catch (e) {
      _log.warning('persist inflight $requestId failed: $e', tag: _tag, error: e);
    }
  }

  void _clearPersistedTurn(String requestId) {
    _persistTimers.remove(requestId)?.cancel();
    unawaited(_storage.deleteInflightTurn(requestId));
  }

  // ── 发送（消费方 → 提供方） ────────────────────────────────────────────

  /// Push [attachment] bytes to the peer host under [remoteAgentId]'s runtime.
  ///
  /// Returns `(fileId, hostStoreUri)` acknowledged by the host.
  /// [sessionId] scopes the host channel (`peer__…__s_…`).
  Future<({String fileId, String? storeUri})> pushFile({
    required String peerId,
    required String remoteAgentId,
    required AttachmentData attachment,
    String? sessionId,
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
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
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

    late final String? hostStoreUri;
    try {
      hostStoreUri =
          await pending.end.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      clearPending();
      throw Exception('推送附件超时: ${attachment.fileName}');
    } catch (e) {
      clearPending();
      rethrow;
    }
    clearPending();
    return (fileId: fileId, storeUri: hostStoreUri);
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
    /// Fired once [requestId] is allocated, before the control frame is sent.
    void Function(String requestId)? onRequestStarted,
    ACPCancellationToken? cancelToken,
    String? localAgentId,
    String? channelId,
    String? userMessageId,
    String? userId,
    String? userName,
    String? agentName,
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
        final pushed = await pushFile(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          attachment: att,
          sessionId: sessionId,
        );
        attachmentRefs.add(att.toPeerRefJson(
          pushed.fileId,
          stripClientStoreUri: true,
        ));
      }
    }

    final requestId = _uuid.v4();
    final effectiveSessionId = sessionId ?? '';
    if (hasInflightForSession(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: effectiveSessionId,
    )) {
      throw const PeerTurnInFlightException();
    }
    final pending = _PendingRequest(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId ?? '',
      channelId: channelId ?? '',
      sessionId: effectiveSessionId,
      userMessageId: userMessageId ?? '',
      userId: userId ?? '',
      userName: userName ?? '',
      agentName: agentName ?? '',
      onChunk: onChunk,
      onActionConfirmation: onActionConfirmation,
      onMetadata: onMetadata,
    );
    _pending[requestId] = pending;
    _requestAgents[requestId] = (peerId: peerId, remoteAgentId: remoteAgentId);
    if (_requestAgents.length > 200) {
      _requestAgents.remove(_requestAgents.keys.first);
    }
    onRequestStarted?.call(requestId);
    unawaited(_persistTurnNow(requestId));

    cancelToken?.addOnCancelled(() {
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_cancel',
        'request_id': requestId,
      }));
      final p = _pending.remove(requestId);
      if (p != null && !p.completer.isCompleted) {
        // 断连挂起期间的取消：上面的 sendControl 大概率发不出去（连接已断），
        // 登记下来，重连后补发 cancel 而不是 resume（见 _resumeSuspendedTurns）。
        if (p.suspendedSince != null) {
          _cancelledWhileSuspended[requestId] = peerId;
          if (_cancelledWhileSuspended.length > 100) {
            _cancelledWhileSuspended.remove(
              _cancelledWhileSuspended.keys.first,
            );
          }
        }
        p.completer.complete(
          PeerChatResult(content: '[Stopped]', requestId: requestId),
        );
        _clearPersistedTurn(requestId);
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
      _clearPersistedTurn(requestId);
      throw Exception('配对设备未连接，无法发送');
    }

    _log.info(
      'agent_chat sent requestId=$requestId peerId=$peerId '
      'remoteAgentId=$remoteAgentId sessionId=${sessionId ?? '-'} '
      'attachments=${attachmentRefs?.length ?? 0}',
      tag: 'PeerAgentClient',
    );

    final result = await _awaitTurnCompletion(requestId, pending, peerId);
    return PeerChatResult(
      content: result.content,
      metadata: result.metadata,
      requestId: requestId,
    );
  }

  /// Await the turn with an approval-aware watchdog.
  ///
  /// [chatTimeout] only runs while no approval card is open and the agent has
  /// produced no output for that duration: streaming chunks/metadata reset the
  /// idle clock, and the time the user spends reading a tool approval must not
  /// count against the turn — the bridge allows 20 minutes per approval.
  ///
  /// Suspended turns (peer disconnected, waiting for resume) freeze the idle
  /// clock too — the remote can't possibly send frames while the link is
  /// down — but are bounded by [suspendWaitHardCap].
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
      final verdict = evaluateTurnWatchdog(
        now: DateTime.now(),
        startedAt: startedAt,
        idleSince: pending.idleSince,
        suspendedSince: pending.suspendedSince,
        openApprovals: pending.openApprovals,
        chatTimeout: chatTimeout,
        suspendWaitHardCap: suspendWaitHardCap,
        approvalWaitHardCap: approvalWaitHardCap,
      );
      if (verdict != TurnWatchdogVerdict.none) {
        timer.cancel();
        _timeoutRequest(
          requestId,
          peerId,
          duringApproval: pending.openApprovals > 0,
          duringSuspend: verdict == TurnWatchdogVerdict.suspendCap,
        );
      }
    });
    try {
      return await pending.completer.future;
    } finally {
      watchdog.cancel();
    }
  }

  /// 登记一个「本地判死、但远端可能已完成」的 turn —— 重连后应对其所属
  /// agent 做一次历史 reconcile（结果可能仍留在远端 transcript）。
  void _markReconcileNeeded(String requestId) {
    final owner = _requestAgents[requestId];
    if (owner == null) return;
    final key = '${owner.peerId}::${owner.remoteAgentId}';
    _reconcileNeeded.add(key);
    if (_reconcileNeeded.length > 50) {
      _reconcileNeeded.remove(_reconcileNeeded.first);
    }
    _log.info(
      'marked history reconcile for $key (turn $requestId failed remotely-recoverable)',
      tag: _tag,
    );
  }

  /// 重连成功后把该 peer 的 reconcile 提示发出去（聊天页据此触发增量同步）。
  void _flushReconcileHints(String peerId) {
    if (_reconcileNeeded.isEmpty) return;
    for (final key in _reconcileNeeded.toList()) {
      if (!key.startsWith('$peerId::')) continue;
      _reconcileNeeded.remove(key);
      _log.info('reconnected → request history reconcile for $key', tag: _tag);
      _reconcileController.add(key);
    }
  }

  /// Shared timeout path: drop the pending entry so late frames are ignored,
  /// tell the remote to abort so its side does not keep running, and fail
  /// the future.
  void _timeoutRequest(
    String requestId,
    String peerId, {
    required bool duringApproval,
    bool duringSuspend = false,
  }) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    _clearPersistedTurn(requestId);
    unawaited(PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_cancel',
      'request_id': requestId,
    }));
    if (duringSuspend) {
      // 断连期间 cancel 到不了对端 —— hub 侧的 turn 会继续跑完并保留结果。
      // 登记下来，重连后用历史同步把结果补回对话。
      _markReconcileNeeded(requestId);
    }
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    _log.warning(
      'chat timeout requestId=$requestId duringApproval=$duringApproval '
      'duringSuspend=$duringSuspend openApprovals=${p.openApprovals}',
      tag: 'PeerApproval',
    );
    p.completer.completeError(
      TimeoutException(
        duringSuspend
            ? '重连超时，对话中断'
            : duringApproval
                ? '审批等待超时，请重新发送消息'
                : '对端 agent 响应超时（${chatTimeout.inSeconds}s）',
        duringSuspend ? suspendWaitHardCap : chatTimeout,
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
      case 'agent_turn_resume_resp':
        _onTurnResumeResp(event.data);
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
      case 'agent_modes_resp':
        _onModesResp(event.data);
        break;
      case 'agent_modes_set_resp':
        _onModesSetResp(event.data);
        break;
      case 'agent_soul_resp':
        _onSoulResp(event.data);
        break;
      case 'agent_soul_set_resp':
        _onSoulSetResp(event.data);
        break;
      case 'agent_manage_resp':
        _onManageResp(event.data);
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
    final storeUri = data['store_uri'] as String?;

    void failBegin() {
      if (!pending.begin.isCompleted) {
        pending.begin.completeError(Exception(error));
      }
    }

    void failEnd() {
      if (!pending.end.isCompleted) {
        pending.end.completeError(Exception(error));
      }
    }

    void succeedBegin() {
      if (!pending.begin.isCompleted) pending.begin.complete();
    }

    void succeedEnd([String? uri]) {
      if (!pending.end.isCompleted) pending.end.complete(uri);
    }

    if (stage == 'begin') {
      if (ok) {
        succeedBegin();
      } else {
        failBegin();
        failEnd();
        _pendingFilePushes.remove(fileId);
      }
      return;
    }

    // stage == end (or legacy ack without stage)
    if (ok) {
      // If begin was skipped somehow, still unblock it.
      succeedBegin();
      succeedEnd(storeUri);
    } else {
      failBegin();
      failEnd();
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

  /// Fetch upstream session modes (`agent.modes.list` relay). Returns empty
  /// list on failure/timeout. [sessionId] scopes to a synced session.
  Future<PeerModesList> fetchModes({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    if (_pendingModes.containsKey(remoteAgentId)) {
      return _pendingModes[remoteAgentId]!.future;
    }
    final completer = Completer<PeerModesList>();
    _pendingModes[remoteAgentId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_modes_req',
      'agent_id': remoteAgentId,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingModes.remove(remoteAgentId);
      return const PeerModesList(modes: []);
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModes.remove(remoteAgentId);
      return const PeerModesList(modes: []);
    });
  }

  void _onModesResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final raw = (data['modes'] as List?) ?? const [];
    final modes = <PeerAgentMode>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final parsed = PeerAgentMode.fromJson(Map<String, dynamic>.from(item));
      if (parsed != null) modes.add(parsed);
    }
    final current = data['current'] as String?;
    final completer = _pendingModes.remove(remoteId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(PeerModesList(modes: modes, current: current));
    }
  }

  /// Switch the upstream session mode (`agent.modes.setCurrent` relay).
  Future<bool> setMode({
    required String peerId,
    required String remoteAgentId,
    required String mode,
    String? sessionId,
  }) async {
    final key = '$remoteAgentId::$mode';
    if (_pendingModeSet.containsKey(key)) return _pendingModeSet[key]!.future;
    final completer = Completer<bool>();
    _pendingModeSet[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_modes_set_req',
      'agent_id': remoteAgentId,
      'mode': mode,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingModeSet.remove(key);
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModeSet.remove(key);
      return false;
    });
  }

  void _onModesSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final mode = data['mode'] as String?;
    if (remoteId == null || mode == null) return;
    final ok = data['ok'] == true;
    final completer = _pendingModeSet.remove('$remoteId::$mode');
    if (completer != null && !completer.isCompleted) completer.complete(ok);
  }

  /// Fetch soul from a shared peer agent (`agent_soul_req` relay).
  Future<PeerSoulInfo?> fetchSoulInfo({
    required String peerId,
    required String remoteAgentId,
  }) async {
    if (_pendingSoulGet.containsKey(remoteAgentId)) {
      return _pendingSoulGet[remoteAgentId]!.future;
    }
    final completer = Completer<PeerSoulInfo?>();
    _pendingSoulGet[remoteAgentId] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_soul_req',
      'agent_id': remoteAgentId,
    });
    if (!sent) {
      _pendingSoulGet.remove(remoteAgentId);
      return null;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingSoulGet.remove(remoteAgentId);
      return null;
    });
  }

  /// Convenience: soul text only (empty string when missing).
  Future<String?> fetchSoul({
    required String peerId,
    required String remoteAgentId,
  }) async {
    final info = await fetchSoulInfo(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    return info?.soul;
  }

  void _onSoulResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final completer = _pendingSoulGet.remove(remoteId);
    if (completer == null || completer.isCompleted) return;
    if (data['ok'] != true) {
      completer.complete(null);
      return;
    }
    completer.complete(PeerSoulInfo(
      soul: data['soul'] as String? ?? '',
      editable: data['editable'] == true,
    ));
  }

  /// Update soul on a shared peer agent when host allows it.
  Future<bool> setSoul({
    required String peerId,
    required String remoteAgentId,
    required String soul,
  }) async {
    if (_pendingSoulSet.containsKey(remoteAgentId)) {
      return _pendingSoulSet[remoteAgentId]!.future;
    }
    final completer = Completer<bool>();
    _pendingSoulSet[remoteAgentId] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_soul_set_req',
      'agent_id': remoteAgentId,
      'soul': soul,
    });
    if (!sent) {
      _pendingSoulSet.remove(remoteAgentId);
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingSoulSet.remove(remoteAgentId);
      return false;
    });
  }

  void _onSoulSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final ok = data['ok'] == true;
    final completer = _pendingSoulSet.remove(remoteId);
    if (completer != null && !completer.isCompleted) completer.complete(ok);
  }

  /// Remote instance control: list / start / stop / set_enabled.
  Future<PeerAgentManageResult> manageAgents({
    required String peerId,
    required String op,
    String? agentId,
    bool? enabled,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerAgentManageResult>();
    _pendingManage[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_manage_req',
      'request_id': requestId,
      'op': op,
      if (agentId != null) 'agent_id': agentId,
      if (enabled != null) 'enabled': enabled,
    };
    final sent = await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(ok: false, error: 'offline');
    }
    return completer.future.timeout(const Duration(seconds: 20), onTimeout: () {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    });
  }

  void _onManageResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final completer = _pendingManage.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    final raw = (data['agents'] as List?) ?? const [];
    final agents = <PeerAgentManageEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      agents.add(PeerAgentManageEntry.fromJson(Map<String, dynamic>.from(item)));
    }
    final error = data['error'] as String?;
    completer.complete(PeerAgentManageResult(
      ok: data['ok'] == true,
      error: error,
      agents: agents,
      unsupported: error == 'unsupported',
    ));
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

  /// Drop a redundant `psess_` shell when the live legacy channel already
  /// binds the same remote session id.
  Future<void> _removeDuplicatePeerSessionShell({
    required String preferredChannelId,
    required String duplicateChannelId,
  }) async {
    try {
      await _db.deleteChannelMessages(duplicateChannelId);
      await _db.deleteChannel(duplicateChannelId);
      _log.info(
        'Removed duplicate peer session channel $duplicateChannelId '
        '(kept $preferredChannelId)',
        tag: _tag,
      );
    } catch (e, st) {
      _log.warning(
        'Failed to dedupe peer session channels '
        '$duplicateChannelId → $preferredChannelId: $e\n$st',
        tag: _tag,
        error: e,
      );
    }
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
      final psessId = syncedPeerChannelId(s.sessionId);
      final legacyId = s.sessionId;
      final psessExisting = await _db.getChannelById(psessId);
      final legacyExisting = await _db.getChannelById(legacyId);
      if (legacyExisting != null && psessExisting != null) {
        await _removeDuplicatePeerSessionShell(
          preferredChannelId: legacyId,
          duplicateChannelId: psessId,
        );
      }
      final channelId = resolveLocalPeerChannelId(
        s.sessionId,
        psessExists: psessExisting != null,
        legacyExists: legacyExisting != null,
      );
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
    final remoteSessionIds =
        sessions.map((s) => s.sessionId).toSet();
    final prioritizeSessionId = peerRemoteSessionIdForLocalChannel(
      prioritizeChannelId,
      knownRemoteSessionIds: remoteSessionIds,
    );
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
        final psessId = syncedPeerChannelId(session.sessionId);
        final legacyId = session.sessionId;
        final channelId = resolveLocalPeerChannelId(
          session.sessionId,
          psessExists: await _db.getChannelById(psessId) != null,
          legacyExists: await _db.getChannelById(legacyId) != null,
        );
        if (hasInflightForChannel(channelId)) {
          _log.info(
            'skip history sync for $channelId — inflight turn in progress',
            tag: _tag,
          );
          if (prioritizeSessionId != null &&
              session.sessionId == prioritizeSessionId) {
            prioritizedDone = true;
            if (onPrioritizedChannelDone != null) {
              await onPrioritizedChannelDone(0);
            }
          }
          continue;
        }
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
    final remoteSessionId =
        remoteSessionIdFromChannelId(channelId) ?? channelId;

    final history = await fetchHistory(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: remoteSessionId,
    );
    if (history.isEmpty) return 0;

    final existing = await _db.getChannelMessages(channelId, limit: 2000);
    final existingAsc = existing.reversed.toList();
    final existingById = <String, DateTime>{};
    final existingRowsById = <String, Map<String, dynamic>>{};
    for (final row in existingAsc) {
      final id = row['id'] as String?;
      final rawAt = row['created_at'] as String?;
      if (id == null || rawAt == null) continue;
      existingRowsById[id] = row;
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
    // content, resolved send times, and progress sections.
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
        if (_rowProgressContent(row) != (history[i].progressContent ?? '')) {
          identical = false;
          break;
        }
      }
      if (identical) return 0;
    }

    final remoteIds = <String>{};
    final remoteRoleContentKeys = <String>{};
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isUser = m.role == 'user';
      final msgId = peerHistoryMessageId(m, channelId, i);
      remoteIds.add(msgId);
      remoteRoleContentKeys.add(peerHistoryRoleContentKey(m.role, m.content));
      // Fold the reconstructed progress section (thinking/tools/plan) into the
      // same metadata shape the live stream produces — the bubble renders it
      // as one collapsible block above the answer.
      final metadata = peerHistoryMessageMetadata(m);
      final isRead = preservedReadStateForHistorySync(
        remote: m,
        existingRow: existingRowsById[msgId],
      );
      await _db.createMessage(
        id: msgId,
        channelId: channelId,
        senderId: isUser ? userId : localAgentId,
        senderType: isUser ? 'user' : 'agent',
        senderName: isUser ? userName : agentName,
        content: m.content,
        metadata: metadata,
        createdAt: createdAts[i],
        isRead: isRead,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    // Drop stale remote-mirrored rows, but keep live local messages that the
    // remote transcript does not yet contain (in-flight user send, streaming
    // partials). Otherwise a sync mid-turn deletes the new uuid bubble and
    // the previous assistant reply looks like the answer to the new message.
    final preserveIds = <String>{};
    for (final rec in snapshotInflightTurns()) {
      if (rec.channelId != channelId) continue;
      if (rec.userMessageId.isNotEmpty) preserveIds.add(rec.userMessageId);
      if (rec.partialMessageId != null && rec.partialMessageId!.isNotEmpty) {
        preserveIds.add(rec.partialMessageId!);
      }
    }
    final localRows = existingAsc.map((row) {
      return PeerHistorySyncLocalRow(
        id: row['id'] as String? ?? '',
        senderType: row['sender_type'] as String? ?? '',
        content: row['content'] as String? ?? '',
        metadataJson: row['metadata'] as String?,
      );
    });
    final toDelete = localMessageIdsToDeleteOnPeerHistorySync(
      localRows: localRows,
      remoteIds: remoteIds,
      remoteRoleContentKeys: remoteRoleContentKeys,
      preserveIds: preserveIds,
    );
    for (final id in toDelete) {
      await _db.deleteMessage(id);
    }

    // User is actively viewing this channel — synced rows must not resurrect
    // unread (covers the loadMessages ↔ syncHistory race on chat entry).
    if (AppLifecycleService().shouldSuppressNotification(channelId)) {
      await _db.markChannelMessagesAsRead(channelId);
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
    unawaited(_applyCommandsResp(peerId, remoteId, commands));
  }

  Future<void> _applyCommandsResp(
    String peerId,
    String remoteId,
    List<SlashCommandInfo> commands,
  ) async {
    final localId = await resolvePeerAgentRowId(_db, peerId, remoteId);
    _commandsCache[localId] = commands;
    // Also index by Hub UUID so callers that already reuse remote id hit cache.
    if (localId != remoteId) {
      _commandsCache[remoteId] = commands;
    }
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

    // E24：裁决已提交成功（但 hub 没收到 resp）的卡片被重发 —— 用存储的
    // 裁决自动应答，不重复计数、不重复弹卡。保留记录以便多次重连仍能自动应答。
    final submitted = _submittedApprovals[approvalId];
    if (submitted != null) {
      _log.info(
        'agent_approval_req: approvalId=$approvalId already submitted — '
        'auto-replying stored verdict action=${submitted.actionId}',
        tag: 'PeerApproval',
      );
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_approval_resp',
        'approval_id': approvalId,
        'selected_action_id': submitted.actionId,
        if (submitted.label != null && submitted.label!.isNotEmpty)
          'selected_action_label': submitted.label,
      }));
      return;
    }

    if (pending == null) {
      // 幂等：同一 orphan 卡被 hub 重发时不重复灌 orphan 流（避免 UI 重置已选状态）。
      if (_orphanedApprovals.containsKey(approvalId)) {
        _log.info(
          'agent_approval_req: duplicate orphan approvalId=$approvalId — '
          'skip UI refresh',
          tag: 'PeerApproval',
        );
        return;
      }
      // agent_done may have already completed the request (hub/client race).
      // Keep a deferred slot so a late UI path can still submit the verdict.
      _log.warning(
        'agent_approval_req: no pending request for requestId=$requestId — '
        'buffering as orphan approvalId=$approvalId',
        tag: 'PeerApproval',
      );
      _orphanedApprovals[approvalId] = Map<String, dynamic>.from(data);
    } else {
      // 幂等：hub 重连后会重发同一张卡片。已在计数的 approvalId 不重复
      // openApprovals++（否则一次点击永远还不清，bufferedDone 卡死），也不再
      // 转发 UI（否则会清掉已选状态 / 在 submit 途中重绘未选中卡）。
      if (_approvalToRequest.containsKey(approvalId)) {
        _log.info(
          'agent_approval_req: duplicate card approvalId=$approvalId — '
          'not double-counting, skip UI refresh',
          tag: 'PeerApproval',
        );
        return;
      }
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
    // 过期卡片守卫：approvalId 既不属于活动 turn（_approvalToRequest），也不是
    // hub 重放的孤儿审批（_orphanedApprovals），说明结果已提交或 turn 已失败
    // 且 hub 尚未重发 —— 此时发出去的裁决只会被对端丢弃（NO MATCH），用户却
    // 看到「点击成功」的假象。直接报错让 UI 提示。
    final tracked = _approvalToRequest.containsKey(approvalId) ||
        _orphanedApprovals.containsKey(approvalId);
    if (!tracked) {
      _log.warning(
        'submitApproval: unknown/expired approvalId=$approvalId — refusing to '
        'send a verdict that would be dropped remotely',
        tag: 'PeerApproval',
      );
      throw const PeerApprovalExpiredException();
    }
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
    // 孤儿审批提交成功后清掉占位，避免重复点击落到 NO MATCH。
    _orphanedApprovals.remove(approvalId);
    // 记录已提交的裁决：若 hub 其实没收到 resp（断连恰好发生在发送后），
    // 重连后 hub 会重发该卡片 —— _onApprovalReq 用此记录自动应答（E24）。
    _submittedApprovals[approvalId] = (
      actionId: selectedActionId,
      label: selectedActionLabel,
    );
    if (_submittedApprovals.length > 50) {
      _submittedApprovals.remove(_submittedApprovals.keys.first);
    }
    if (requestId != null) {
      final pending = _pending[requestId];
      if (pending != null && pending.openApprovals > 0) {
        pending.openApprovals--;
        if (pending.openApprovals == 0) {
          // Verdict is on the wire — idle clock runs from here.
          pending.idleSince = DateTime.now();
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
    final p = _pending[requestId];
    if (p == null) return;
    // 先计数再分发：与 hub 的 accumulated 同序列（同为 UTF-16 码元长度），
    // resume 的断点偏移才精确。
    p.receivedLength += content.length;
    if (content.isNotEmpty) {
      p.idleSince = DateTime.now();
    }
    p.onChunk?.call(content);
    _schedulePersist(requestId);
  }

  void _onMetadata(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final raw = data['metadata'];
    final metadata = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    if (metadata.isEmpty) return;
    final p = _pending[requestId];
    if (p == null) return;
    p.idleSince = DateTime.now();
    p.onMetadata?.call(metadata);
  }

  void _finishPending(String requestId, Map<String, dynamic> data) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    _clearPersistedTurn(requestId);
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    p.completer.complete(PeerChatResult(
      content: data['content'] as String? ?? '',
      metadata: (data['metadata'] as Map?)?.cast<String, dynamic>(),
      requestId: requestId,
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
    _clearPersistedTurn(requestId);
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
      if (_handlersReadyForResume) {
        unawaited(_resumeSuspendedTurns(event.peerId));
      }
      _flushReconcileHints(event.peerId);
    } else if (event.type == PeerConnectionEventType.disconnected) {
      _suspendPendingForPeer(event.peerId);
      unawaited(_markPeerAgentsOffline(event.peerId));
    }
  }

  /// PeerConnectionManager.resumeAll 的征询钩子：该 peer 是否存在尚未完成的
  /// sendChat turn（含审批待决）。有则恢复前台时连接必须保留 —— 掐断会让
  /// hub 把在途审批按放弃处理，整个 turn 随之死亡。
  bool _hasInFlightTurnForPeer(String peerId) {
    for (final p in _pending.values) {
      if (p.peerId == peerId && !p.completer.isCompleted) return true;
    }
    return false;
  }

  /// Peer 断连时把在途 turn 挂起（suspended）而不是判死：hub 侧的 turn 在
  /// peer 级注册表里存活（输出路由到「当前活连接」），重连后经
  /// `agent_turn_resume_req` 按 receivedLength 断点续传。只有重连超过
  /// [suspendWaitHardCap] 仍无望时才由看门狗判失败。
  void _suspendPendingForPeer(String peerId) {
    var count = 0;
    for (final p in _pending.values) {
      if (p.peerId != peerId || p.completer.isCompleted) continue;
      p.suspendedSince ??= DateTime.now();
      // 允许重连后重新发起 resume
      p.resumeInFlight = false;
      p.resumeBaseLength = null;
      count++;
    }
    if (count > 0) {
      _log.warning(
        'peer disconnected — suspending $count in-flight turn(s) for resume',
        tag: 'PeerApproval',
      );
    }
  }

  /// 重连成功后的恢复序列：
  /// 1. 挂起期间本地取消的 turn → 补发 agent_cancel；
  /// 2. 其余挂起的 turn → 发 agent_turn_resume_req（断点 = receivedLength），
  ///    并启动应答超时（旧 hub 不支持续传时 10s 后明确失败）。
  Future<void> _resumeSuspendedTurns(String peerId) async {
    // 1. flush 挂起期间本地取消的 turn
    for (final entry in _cancelledWhileSuspended.entries.toList()) {
      if (entry.value != peerId) continue;
      _cancelledWhileSuspended.remove(entry.key);
      _log.info(
        'flush queued cancel requestId=${entry.key}',
        tag: 'PeerApproval',
      );
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_cancel',
        'request_id': entry.key,
      }));
    }

    // 2. 逐 turn 发 resume_req
    for (final entry in _pending.entries) {
      final requestId = entry.key;
      final p = entry.value;
      if (p.peerId != peerId || p.completer.isCompleted) continue;
      if (p.suspendedSince == null) continue;
      // 内容已完整在手（done 已到，只差审批裁决）—— 不需要续传，
      // 走卡片重发路径即可（E38：hub 若重启过，resume 会把成功 turn 误判 lost）。
      if (p.bufferedDone != null) {
        p.suspendedSince = null;
        continue;
      }
      if (p.resumeInFlight) continue;
      p.resumeInFlight = true;
      p.resumeBaseLength = p.receivedLength;
      _log.info(
        'resume turn requestId=$requestId known=${p.receivedLength}',
        tag: 'PeerApproval',
      );
      final sent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_turn_resume_req',
        'request_id': requestId,
        'known_content_length': p.receivedLength,
      });
      if (!sent) {
        // 仍未连通 —— 回滚标志，等下一次 connected 事件重试。
        p.resumeInFlight = false;
        p.resumeBaseLength = null;
        continue;
      }
      // 应答超时：旧 hub 忽略 resume_req（unknown type 无响应）→ 明确失败。
      Timer(resumeResponseTimeout, () {
        final cur = _pending[requestId];
        if (cur == null || cur.completer.isCompleted) return;
        if (!cur.resumeInFlight) return;
        _pending.remove(requestId);
        _clearPersistedTurn(requestId);
        for (final e in _approvalToRequest.entries.toList()) {
          if (e.value == requestId) _approvalToRequest.remove(e.key);
        }
        _log.warning(
          'resume requestId=$requestId timed out — peer hub does not '
          'support turn resume',
          tag: 'PeerApproval',
        );
        _markReconcileNeeded(requestId);
        cur.completer.completeError(
          Exception('对端不支持断点续传或任务已丢失，请重新发送'),
        );
      });
    }
  }

  /// 处理 agent_turn_resume_resp：先经 drop-prefix 去重（重连后 live chunk
  /// 可能先于 resp 到达，与 delta 前缀重叠），再按 status 走既有完成路径。
  void _onTurnResumeResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null) return;
    p.resumeInFlight = false;

    final rawDelta = data['delta'] as String? ?? '';
    final base = p.resumeBaseLength ?? p.receivedLength;
    final delta = applyResumeDelta(
      delta: rawDelta,
      receivedLength: p.receivedLength,
      baseLength: base,
    );
    p.resumeBaseLength = null;

    // 先恢复分流状态（R6：metadata 决定 splitter 对后续 chunk 的分流），
    // 再应用 delta。
    final streamMeta = data['stream_metadata'];
    if (streamMeta is Map) {
      p.onMetadata?.call(Map<String, dynamic>.from(streamMeta));
    }
    if (delta.isNotEmpty) {
      p.receivedLength += delta.length;
      p.idleSince = DateTime.now();
      p.onChunk?.call(delta);
    }
    p.suspendedSince = null;

    final status = data['status'] as String? ?? 'lost';
    _log.info(
      'turn resume resp requestId=$requestId status=$status '
      'delta=${delta.length} (raw=${rawDelta.length})',
      tag: 'PeerApproval',
    );
    switch (status) {
      case 'streaming':
        // 续传成功 —— idle 看门狗从此刻重新计时。
        p.idleSince = DateTime.now();
        break;
      case 'done':
        _onDone({
          'request_id': requestId,
          'content': data['content'] as String? ?? '',
          if (data['metadata'] != null) 'metadata': data['metadata'],
        });
        break;
      case 'error':
        _onError({
          'request_id': requestId,
          'message': data['message'] as String? ?? 'agent error',
        });
        break;
      case 'lost':
      default:
        // hub 已不认识这个 turn（重启或 TTL 过期）——但结果可能已落进
        // 远端 transcript，登记 reconcile，由历史同步补回。
        _markReconcileNeeded(requestId);
        _onError({
          'request_id': requestId,
          'message': data['message'] as String? ?? '对端任务已结束或丢失',
        });
        break;
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

        final localId = await resolvePeerAgentRowId(_db, peerId, remoteId);
        final existing = await _db.getRemoteAgentById(localId);
        final capabilities = (raw['capabilities'] as List?)?.cast<String>() ?? const [];
        final supportedModalities = (raw['supported_modalities'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[];
        final engine = (raw['engine'] as String?)?.trim();
        final avatar = await _resolvePeerAvatar(raw, existing);
        final manageable = raw['manageable'] == true;
        final enabled = raw['enabled'] != false;
        final running = raw['running'] == true;
        final online = !manageable || (enabled && running);

        final agent = RemoteAgent(
          id: localId,
          name: raw['name'] as String? ?? 'Agent',
          avatar: avatar,
          bio: raw['bio'] as String?,
          token: '',
          endpoint: 'peer://$peerId/$remoteId',
          protocol: ProtocolType.peer,
          connectionType: ConnectionType.websocket,
          status: online ? AgentStatus.online : AgentStatus.offline,
          connectedAt: now,
          capabilities: capabilities,
          metadata: {
            'source_peer_id': peerId,
            'source_peer_name': peerName,
            'remote_agent_id': remoteId,
            if (engine != null && engine.isNotEmpty) 'engine': engine,
            if (supportedModalities.isNotEmpty)
              'supported_modalities': supportedModalities,
            if (manageable) 'manageable': true,
            'enabled': enabled,
            'running': running,
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
  /// - 本地已手动改头像（`avatar_overridden`）：始终以本地为准。
  /// - 对端附带了图片字节（`avatar_data`）：解码后写入本地存储，返回其绝对路径；
  ///   若该 peer agent 此前已有本地头像文件，则原地覆盖以保持路径稳定、避免堆积。
  /// - 无字节：直接用 `avatar` 字符串（emoji / asset / 网络 URL 可在本端解析）；
  ///   若是对端本机绝对路径、空值或通用占位 🤖，则按 `engine` 回退到引擎默认头像。
  Future<String> _resolvePeerAvatar(Map raw, RemoteAgent? existing) async {
    // 本地已自定义该 peer agent 头像 → 以本地为准，忽略对端分享的头像。
    final existingAvatar = existing?.avatar;
    if (existing?.metadata['avatar_overridden'] == true &&
        existingAvatar != null &&
        existingAvatar.isNotEmpty) {
      return existingAvatar;
    }

    final engine = (raw['engine'] as String?)?.trim();
    final engineDefault = defaultAvatarForEngine(engine);

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

    final avatar = raw['avatar'] as String? ?? '';
    // 对端的本机绝对路径在本端不存在 → 引擎默认头像。
    if (avatar.startsWith('/') && !avatar.startsWith('http')) {
      return engineDefault;
    }
    // 空值 / 通用占位 → 升级为引擎默认（兼容旧 Hub 仍发 🤖 的情况）。
    if (isGenericDefaultAvatar(avatar)) return engineDefault;
    return avatar;
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

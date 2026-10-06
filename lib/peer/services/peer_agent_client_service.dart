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
import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../models/attachment_data.dart';
import '../../models/channel.dart';
import '../../models/remote_agent.dart';
import '../../models/agent_memory_entry.dart';
import '../../models/acp_protocol.dart';
import '../../services/acp_agent_connection.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../services/session/cli_execute_peer_handler.dart';
import '../../services/session/session_create_peer_handler.dart';
import '../../services/she_agent_impression_service.dart';
import '../../services/she_service.dart';
import '../../service_locator.dart' show getIt;
import '../../utils/engine_avatars.dart';
import '../../utils/session_utils.dart';
import '../../services/messaging/chat_history_content.dart';
import '../../storage/agent_roster.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import '../pouch_duties.dart';
import '../pouch_pair.dart';
import '../pouch_roster.dart';
import '../pouch_turn_relay.dart';
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer_approval_payload.dart';
import 'peer_agent_ids.dart';
import 'peer_connection_manager.dart';
import 'peer_inflight_turn.dart';
import 'peer_storage_service.dart';
import 'peer_turn_resume.dart';
import '../../storage/agent_workspace_uris.dart';
import '../../storage/store_protocol.dart';

export 'peer_agent_ids.dart';
export 'peer_inflight_turn.dart' show PeerTurnInFlightException;

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

/// SharedPreferences key for remote session ids already mirrored with no
/// `updatedAt`. See [selectDirtySessions].
String peerHistoryUnstampedPrefsKey(String localAgentId) =>
    'peer_history_unstamped_$localAgentId';

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
/// session is dirty if `updatedAt >= lastSyncAt - overlap`.
///
/// A session with no `updatedAt` is dirty only until it has been mirrored once.
/// Treating "no stamp" as forever-dirty re-pulls the same Cursor IDE transcripts
/// on every app open; the replay then re-anchors unstamped turns to "now" and
/// those historical sessions sort above conversations just created on device.
/// [syncedUnstampedIds] is that already-mirrored set.
///
/// When [prioritizeSessionId] is set, that session is moved to the front.
List<PeerRemoteSession> selectDirtySessions(
  List<PeerRemoteSession> sessions, {
  DateTime? lastSyncAt,
  Duration overlap = kPeerHistorySyncOverlap,
  String? prioritizeSessionId,
  Set<String> syncedUnstampedIds = const {},
}) {
  final List<PeerRemoteSession> dirty;
  if (lastSyncAt == null) {
    dirty = List<PeerRemoteSession>.of(sessions);
  } else {
    final since = lastSyncAt.subtract(overlap);
    dirty = sessions.where((s) {
      if (s.updatedAt == null) {
        return !syncedUnstampedIds.contains(s.sessionId);
      }
      return !s.updatedAt!.isBefore(since);
    }).toList();
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

/// 本地还没有正文的会话。水位只看远端 `updatedAt`，刚建出来的空壳
/// 往往比水位旧，会被整段跳过，标题在、内容永远空着。
List<PeerRemoteSession> sessionsMissingLocalTranscript(
  List<PeerRemoteSession> sessions, {
  required Set<String> alreadyDirty,
  required Set<String> syncedUnstampedIds,
  required Set<String> emptyLocalSessionIds,
}) {
  return [
    for (final session in sessions)
      if (!alreadyDirty.contains(session.sessionId) &&
          !syncedUnstampedIds.contains(session.sessionId) &&
          emptyLocalSessionIds.contains(session.sessionId))
        session,
  ];
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

  /// 远端完整记录的条数。缺省表示这一来源没给出可靠条数，判脏时退回 `updatedAt`。
  final int? messageCount;

  PeerRemoteSession({
    required this.sessionId,
    this.title,
    this.updatedAt,
    this.messageCount,
  });

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
    } else if (rawUpdated is num) {
      final ms = rawUpdated.toInt();
      if (ms > 0) {
        updated = DateTime.fromMillisecondsSinceEpoch(
          ms < 1000000000000 ? ms * 1000 : ms,
          isUtc: true,
        );
      }
    }
    final title = (json['title'] as String?)?.trim();
    int? messageCount;
    final rawCount = json['message_count'];
    if (rawCount is num) messageCount = rawCount.toInt();
    return PeerRemoteSession(
      sessionId: id,
      title: (title != null && title.isNotEmpty) ? title : null,
      updatedAt: updated,
      messageCount: messageCount,
    );
  }
}

/// 一页 `agent_session_history_resp`。
///
/// [supportsCursor] 只看响应里有没有 `cursor` 字段。旧 Hub 没有这个字段。
class PeerHistoryPage {
  final List<PeerHistoryMessage> messages;
  final int from;
  final int total;
  final String? cursor;
  final bool hasMore;
  final bool reset;
  final bool completed;
  final bool supportsCursor;

  const PeerHistoryPage({
    this.messages = const [],
    this.from = 0,
    this.total = 0,
    this.cursor,
    this.hasMore = false,
    this.reset = false,
    this.completed = false,
    this.supportsCursor = false,
  });

  static const incomplete = PeerHistoryPage();
  static const empty = PeerHistoryPage(completed: true);
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

  /// Hub history protocol annotations (`ui_hidden`, `history_exclude`, `kind`).
  final Map<String, dynamic>? metadata;

  final String? replyTo;

  PeerHistoryMessage({
    required this.role,
    required this.content,
    this.messageId,
    this.createdAt,
    this.progressContent,
    this.progressTitle,
    this.progressAutoCollapse,
    this.metadata,
    this.replyTo,
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
    Map<String, dynamic>? metadata;
    final rawMeta = json['metadata'];
    if (rawMeta is Map) {
      metadata = Map<String, dynamic>.from(rawMeta);
    }
    return PeerHistoryMessage(
      role: role,
      content: content,
      messageId: json['message_id'] as String?,
      createdAt: createdAt,
      progressContent: (rawProgress?.isNotEmpty ?? false) ? rawProgress : null,
      progressTitle: json['progress_title'] as String?,
      progressAutoCollapse: json['progress_auto_collapse'] as bool?,
      metadata: metadata,
      replyTo: json['reply_to'] as String?,
    );
  }
}

/// Assign display timestamps for a synced peer transcript.
///
/// Preference order per message:
/// 1. Protocol [PeerHistoryMessage.createdAt] (filled by agent-bridge)
/// 2. Existing local `created_at` for the same stable id — a resynced row keeps
///    the time it already has, so repeated syncs are idempotent
/// 3. [sessionUpdatedAt] / [fallbackEnd]-anchored synthetic times, one minute
///    apart, for rows the channel does not have yet
///
/// [latestMirroredLocalAt] is a lower bound for the batch, applied only when no
/// message carries a remote stamp: the session-level anchor
/// ([sessionUpdatedAt]) can lag by minutes, and storing it verbatim would sort
/// the whole synthesized batch above messages the channel already shows.
///
/// It must only account for local rows the remote transcript actually contains.
/// Counting a just-sent message that the remote has not committed yet would
/// shift the batch past it, pushing the previous turn's reply *below* the new
/// question — the reply then reads as an answer to it.
List<DateTime> assignPeerHistoryTimestamps(
  List<PeerHistoryMessage> history, {
  Map<String, DateTime> existingById = const {},
  DateTime? sessionUpdatedAt,
  DateTime? fallbackEnd,
  DateTime? latestMirroredLocalAt,
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
  // Only synthesized batches get floored. Remote stamps are authoritative and
  // must land verbatim, otherwise every sync pushes the transcript later than
  // the last one and it drifts past newer local messages.
  final floor = latestMirroredLocalAt;
  if (!anyRemote && floor != null && out.last.isBefore(floor)) {
    final shift = floor.difference(out.last) + const Duration(seconds: 1);
    for (var i = 0; i < out.length; i++) {
      out[i] = out[i].add(shift);
    }
  }
  return out;
}

/// Whether one mirrored row should be written again.
///
/// Role, text, or progress changes always rewrite. A timestamp-only change
/// rewrites only when a remote stamp moves earlier — that corrects a previous
/// import that anchored an unstamped IDE transcript to "now". A later stamp on
/// unchanged text is repeated-sync drift and must be ignored.
bool peerHistoryRowNeedsWrite({
  required PeerHistoryMessage message,
  required Map<String, dynamic>? existingRow,
  required DateTime createdAt,
}) {
  if (existingRow == null) return true;
  final role =
      (existingRow['sender_type'] as String?) == 'user' ? 'user' : 'agent';
  if (role != message.role ||
      (existingRow['content'] as String? ?? '') != message.content) {
    return true;
  }
  if (_rowProgressContent(existingRow) != (message.progressContent ?? '')) {
    return true;
  }
  final localAt = DateTime.tryParse(existingRow['created_at'] as String? ?? '');
  if (localAt == null) return true;
  if (localAt.toUtc().millisecondsSinceEpoch ==
      createdAt.toUtc().millisecondsSinceEpoch) {
    return false;
  }
  return createdAt.toUtc().isBefore(localAt.toUtc());
}

/// Whether [syncHistory] must rewrite local rows for a full transcript.
///
/// A length mismatch rewrites. Otherwise each row uses [peerHistoryRowNeedsWrite].
bool peerHistoryNeedsRewrite({
  required List<PeerHistoryMessage> history,
  required List<Map<String, dynamic>> existingAsc,
  required List<DateTime> createdAts,
}) {
  if (existingAsc.length != history.length ||
      createdAts.length != history.length) {
    return true;
  }
  for (var i = 0; i < history.length; i++) {
    if (peerHistoryRowNeedsWrite(
      message: history[i],
      existingRow: existingAsc[i],
      createdAt: createdAts[i],
    )) {
      return true;
    }
  }
  return false;
}

/// 冷启动和重建每页条数。新版 App 每次请求都带它。Hub 上限是 500。
const int kPeerHistoryPageLimit = 200;

enum PeerHistoryFetchMode { incremental, rebuild }

enum PeerHistoryApplyKind { full, slice, emptyReset }

enum PeerHistoryCursorAction { store, skip, storeEmpty }

/// 游标非空才增量。空字符串、没有记录，都从 0 开始重建。
PeerHistoryFetchMode peerHistoryFetchMode({required String? storedCursor}) {
  if (storedCursor != null && storedCursor.isNotEmpty) {
    return PeerHistoryFetchMode.incremental;
  }
  return PeerHistoryFetchMode.rebuild;
}

/// 本地还没有正文、也没有同步过时，进页先拉当前会话，不必等会话列表。
///
/// 已经有游标（包括远端确实为空）就交给增量同步，避免每次进页都打一次历史请求。
bool peerHistoryShouldPrefetchOpenChannel({
  required int localMessageCount,
  required bool hasCursorRow,
}) {
  return localMessageCount == 0 && !hasCursorRow;
}

/// 新版请求永远带 [limit]。重建的第一页不带 cursor。
({String? cursor, int limit}) peerHistoryHistoryRequest({
  required PeerHistoryFetchMode mode,
  String? cursor,
}) {
  return (
    cursor: mode == PeerHistoryFetchMode.incremental ? cursor : null,
    limit: kPeerHistoryPageLimit,
  );
}

PeerHistoryApplyKind peerHistoryApplyKind({
  required bool supportsCursor,
  required bool reset,
  required bool messagesEmpty,
}) {
  if (!supportsCursor) return PeerHistoryApplyKind.full;
  if (reset && messagesEmpty) return PeerHistoryApplyKind.emptyReset;
  return PeerHistoryApplyKind.slice;
}

/// 需要收尾的重建，中间页不存游标。空的 reset 存一条空游标。
PeerHistoryCursorAction peerHistoryCursorAction({
  required bool supportsCursor,
  required bool reset,
  required bool messagesEmpty,
  required bool needsCleanup,
  required bool hasMore,
  required String? cursor,
}) {
  if (!supportsCursor) return PeerHistoryCursorAction.skip;
  if (reset && messagesEmpty) return PeerHistoryCursorAction.storeEmpty;
  if (needsCleanup && hasMore) return PeerHistoryCursorAction.skip;
  if (cursor == null || cursor.isEmpty) return PeerHistoryCursorAction.skip;
  return PeerHistoryCursorAction.store;
}

/// 一页响应要怎么落库。带消息的 reset 会把这次同步转成需要收尾的重建。
class PeerHistoryStep {
  final PeerHistoryApplyKind kind;
  final bool restartCleanup;
  final PeerHistoryCursorAction cursorAction;
  final bool finishCleanup;

  const PeerHistoryStep({
    required this.kind,
    required this.restartCleanup,
    required this.cursorAction,
    required this.finishCleanup,
  });
}

PeerHistoryStep peerHistoryStep({
  required bool supportsCursor,
  required bool reset,
  required bool messagesEmpty,
  required bool hasMore,
  required String? pageCursor,
  required bool needsCleanup,
}) {
  final kind = peerHistoryApplyKind(
    supportsCursor: supportsCursor,
    reset: reset,
    messagesEmpty: messagesEmpty,
  );
  final restartCleanup = supportsCursor && reset && !messagesEmpty;
  final cleanup = needsCleanup || restartCleanup;
  return PeerHistoryStep(
    kind: kind,
    restartCleanup: restartCleanup,
    cursorAction: peerHistoryCursorAction(
      supportsCursor: supportsCursor,
      reset: reset,
      messagesEmpty: messagesEmpty,
      needsCleanup: kind == PeerHistoryApplyKind.slice && cleanup,
      hasMore: hasMore,
      cursor: pageCursor,
    ),
    finishCleanup: kind == PeerHistoryApplyKind.slice && cleanup && !hasMore,
  );
}

/// 重建收尾：删掉这次重建没再见到、也不在在途回合里的 `peerhist_*` 行。
Set<String> peerHistoryRebuildDeletes({
  required Iterable<String> localPeerhistIds,
  required Set<String> seenIds,
  required Set<String> preserveIds,
}) {
  return {
    for (final id in localPeerhistIds)
      if (!seenIds.contains(id) && !preserveIds.contains(id)) id,
  };
}

/// 切片里需要 upsert 的下标。id 用绝对位置 [from] + i。
List<int> peerHistorySliceWriteIndexes({
  required List<PeerHistoryMessage> history,
  required int from,
  required String channelId,
  required Map<String, Map<String, dynamic>> existingById,
  required List<DateTime> createdAts,
}) {
  final indexes = <int>[];
  for (var i = 0; i < history.length && i < createdAts.length; i++) {
    final id = peerHistoryMessageId(history[i], channelId, from + i);
    if (peerHistoryRowNeedsWrite(
      message: history[i],
      existingRow: existingById[id],
      createdAt: createdAts[i],
    )) {
      indexes.add(i);
    }
  }
  return indexes;
}

/// 增量删除时，`remoteIds` 要带上切片 id 和本地全部 `peerhist_*` id，这样更早的历史不会被删掉。
Set<String> peerHistorySliceDeleteRemoteIds({
  required Iterable<String> sliceIds,
  required Iterable<String> localPeerhistIds,
}) {
  return {...sliceIds, ...localPeerhistIds};
}

/// 远端给了 `message_count`，且和本地游标的 `total` 不一致（或本地还没有游标）。
bool sessionNeedsSyncForMessageCount(
  PeerRemoteSession session,
  Map<String, int> cursorTotals,
) {
  final count = session.messageCount;
  if (count == null) return false;
  final known = cursorTotals[session.sessionId];
  return known == null || known != count;
}

/// 水位、缺正文、`message_count` 三条里满足任意一条就同步。
List<PeerRemoteSession> assembleSessionsToSync({
  required List<PeerRemoteSession> sessions,
  required DateTime? lastSyncAt,
  Duration overlap = kPeerHistorySyncOverlap,
  required Set<String> syncedUnstampedIds,
  required Set<String> emptyLocalSessionIds,
  required Map<String, int> cursorTotals,
  String? prioritizeSessionId,
  String? openEmptySessionId,
}) {
  final dirty = selectDirtySessions(
    sessions,
    lastSyncAt: lastSyncAt,
    overlap: overlap,
    prioritizeSessionId: prioritizeSessionId,
    syncedUnstampedIds: syncedUnstampedIds,
  );
  final openEmpty = openEmptySessionId;
  if (openEmpty != null &&
      openEmpty.isNotEmpty &&
      !dirty.any((item) => item.sessionId == openEmpty)) {
    dirty.insert(0, PeerRemoteSession(sessionId: openEmpty));
  }
  dirty.addAll(sessionsMissingLocalTranscript(
    sessions,
    alreadyDirty: dirty.map((item) => item.sessionId).toSet(),
    syncedUnstampedIds: syncedUnstampedIds,
    emptyLocalSessionIds: emptyLocalSessionIds,
  ));
  for (final session in sessions) {
    if (!sessionNeedsSyncForMessageCount(session, cursorTotals)) continue;
    if (dirty.any((item) => item.sessionId == session.sessionId)) continue;
    dirty.add(session);
  }
  final prioritize = prioritizeSessionId;
  if (prioritize != null && prioritize.isNotEmpty) {
    final index = dirty.indexWhere((item) => item.sessionId == prioritize);
    if (index > 0) {
      dirty.insert(0, dirty.removeAt(index));
    }
  }
  return dirty;
}

String peerHistoryMessageId(PeerHistoryMessage m, String channelId, int index) {
  if (m.messageId != null && m.messageId!.isNotEmpty) {
    return 'peerhist_${m.messageId}';
  }
  return 'peerhist_${channelId}_$index';
}

/// Hub `reply_to` is the remote message id. Synced rows are stored as
/// `peerhist_<id>`, so the local reply link has to use that same id.
String? peerHistoryReplyToId(String? replyTo) {
  final raw = replyTo?.trim() ?? '';
  if (raw.isEmpty) return null;
  if (raw.startsWith('peerhist_')) return raw;
  return 'peerhist_$raw';
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
  final meta = <String, dynamic>{};
  final protocol = m.metadata;
  if (protocol != null) {
    if (protocol['ui_hidden'] == true) {
      meta[ChatHistoryContent.uiHiddenMetaKey] = true;
    }
    if (protocol['history_exclude'] == true) {
      meta[ChatHistoryContent.historyExcludeMetaKey] = true;
    }
    final kind = protocol['kind'];
    if (kind is String && kind.isNotEmpty) {
      meta['kind'] = kind;
    }
    final quote = protocol['reply_quote'];
    if (quote is String && quote.isNotEmpty) {
      meta['reply_quote'] = quote;
    }
  }
  final progress = m.progressContent;
  if (progress != null && progress.isNotEmpty) {
    meta['progress_content'] = progress;
    meta['collapsible'] = true;
    meta['collapsible_title'] = m.progressTitle ?? 'Details';
    meta['auto_collapse'] = m.progressAutoCollapse ?? true;
  }
  return meta.isEmpty ? null : meta;
}

/// Hub transcript 落库：隐藏纯 Scope Card 行；可剥离前缀时写入展示正文。
({String content, Map<String, dynamic>? metadata}) peerHistoryDisplayFields(
  PeerHistoryMessage m, {
  Map<String, dynamic>? baseMetadata,
}) {
  final meta = baseMetadata != null
      ? Map<String, dynamic>.from(baseMetadata)
      : <String, dynamic>{};
  final wire = m.content;
  if (meta[ChatHistoryContent.uiHiddenMetaKey] == true) {
    return (content: wire, metadata: meta);
  }
  if (SessionUtils.isHubInternalPromptArtifact(wire)) {
    meta[ChatHistoryContent.uiHiddenMetaKey] = true;
    meta[ChatHistoryContent.historyExcludeMetaKey] = true;
    return (content: wire, metadata: meta);
  }
  final stripped = SessionUtils.stripHubInternalPromptForDisplay(wire);
  if (stripped != null && stripped != wire) {
    meta['wire_content'] = wire;
    return (content: stripped, metadata: meta.isEmpty ? null : meta);
  }
  return (content: wire, metadata: meta.isEmpty ? null : meta);
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
  final stored = existingRow['content'] as String? ?? '';
  if (stored != remote.content &&
      _rowWireContent(existingRow) != remote.content) {
    return 0;
  }
  return existingRow['is_read'] as int? ?? 0;
}

/// `wire_content` kept beside a synced row, or null when absent.
String? _rowWireContent(Map<String, dynamic> row) {
  final raw = row['metadata'];
  Map<String, dynamic>? meta;
  if (raw is Map) {
    meta = Map<String, dynamic>.from(raw);
  } else if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) meta = Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  final wire = meta?['wire_content'];
  return wire is String && wire.isNotEmpty ? wire : null;
}

/// 模型参数，例如 Cursor 的 Fast。字段名对应 Hub 的 `options[]`。
class PeerModelOption {
  final String id;
  final String displayName;
  final String description;
  final List<String> values;
  final List<String> labels;
  final String defaultValue;

  const PeerModelOption({
    required this.id,
    required this.displayName,
    this.description = '',
    this.values = const [],
    this.labels = const [],
    this.defaultValue = '',
  });

  /// Fast 用胶囊开关，其余参数进二级菜单。
  bool get isSwitch => id == 'fast';

  String labelFor(String value) {
    final index = values.indexOf(value);
    if (index >= 0 && index < labels.length && labels[index].isNotEmpty) {
      return labels[index];
    }
    return formatCursorOptionValue(id, value);
  }

  static PeerModelOption? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    if (id.isEmpty) return null;
    final display = (json['display_name'] as String?)?.trim();
    final values = _stringList(json['values']);
    final labels = _stringList(json['labels']);
    final fallback = json['default'];
    return PeerModelOption(
      id: id,
      displayName: (display != null && display.isNotEmpty) ? display : id,
      description: (json['description'] as String?) ?? '',
      values: values,
      labels: labels,
      defaultValue: fallback is String ? fallback : '',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'display_name': displayName,
        'description': description,
        'values': values,
        if (labels.isNotEmpty) 'labels': labels,
        'default': defaultValue,
      };
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  final values = <String>[];
  for (final item in raw) {
    if (item is String && item.isNotEmpty) values.add(item);
  }
  return values;
}

/// Hub 没给展示文案时，把 `500k` / `high` 显示成 Cursor 菜单里的样子。
String formatCursorOptionValue(String id, String value) {
  switch (id) {
    case 'context':
      if (value.endsWith('k') || value.endsWith('m')) {
        return '${value.substring(0, value.length - 1)}${value[value.length - 1].toUpperCase()}';
      }
      return value;
    case 'reasoning_effort':
      switch (value) {
        case 'low':
          return 'Low';
        case 'medium':
        case 'med':
          return 'Medium';
        case 'high':
          return 'High';
        case 'xhigh':
        case 'extra-high':
        case 'extra_high':
          return 'Extra High';
        case 'max':
          return 'Max';
        default:
          if (value.isEmpty) return value;
          return '${value[0].toUpperCase()}${value.substring(1)}';
      }
    default:
      return value;
  }
}

/// One upstream model option from `agent_models_resp`.
class PeerAgentModel {
  final String value;
  final String displayName;
  final String description;
  final List<PeerModelOption> options;

  PeerAgentModel({
    required this.value,
    required this.displayName,
    this.description = '',
    this.options = const [],
  });

  PeerModelOption? optionById(String id) {
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  static PeerAgentModel? fromJson(Map<String, dynamic> json) {
    final value = json['value'] as String?;
    if (value == null || value.isEmpty) return null;
    final display = (json['display_name'] as String?)?.trim();
    final rawOptions = json['options'];
    final options = <PeerModelOption>[];
    if (rawOptions is List) {
      for (final item in rawOptions) {
        if (item is! Map) continue;
        final parsed =
            PeerModelOption.fromJson(Map<String, dynamic>.from(item));
        if (parsed != null) options.add(parsed);
      }
    }
    return PeerAgentModel(
      value: value,
      displayName: (display != null && display.isNotEmpty) ? display : value,
      description: (json['description'] as String?) ?? '',
      options: options,
    );
  }

  Map<String, dynamic> toJson() => {
        'value': value,
        'display_name': displayName,
        'description': description,
        if (options.isNotEmpty)
          'options': [for (final option in options) option.toJson()],
      };
}

/// Upstream model list + current selection (`agent_models_resp`).
///
/// [switchable] 缺省为 true，兼容不发这个字段的旧 Hub。false 表示模型在
/// 对端电脑上配置，App 只能展示当前值。
///
/// [optionValues] 是 Agent 级覆盖（如 `fast: false`）。缺省为空，兼容旧缓存。
class PeerModelsList {
  final List<PeerAgentModel> models;
  final String? current;
  final bool switchable;
  final Map<String, String> optionValues;

  const PeerModelsList({
    required this.models,
    this.current,
    this.switchable = true,
    this.optionValues = const {},
  });

  /// 当前模型该参数的生效值：覆盖值优先，否则用模型默认值。
  /// 当前模型不支持这个参数时返回 null。
  String? effectiveOption(String optionId) {
    final currentId = current;
    if (currentId == null || currentId.isEmpty) return null;
    PeerAgentModel? model;
    for (final item in models) {
      if (item.value == currentId) {
        model = item;
        break;
      }
    }
    final option = model?.optionById(optionId);
    if (option == null) return null;
    final override = optionValues[optionId];
    if (override != null &&
        override.isNotEmpty &&
        (option.values.isEmpty || option.values.contains(override))) {
      return override;
    }
    if (option.defaultValue.isEmpty) return null;
    return option.defaultValue;
  }

  /// 生效值的展示文案。当前模型没有这个参数时返回 null。
  String? effectiveOptionLabel(String optionId) {
    final value = effectiveOption(optionId);
    if (value == null) return null;
    final currentId = current;
    if (currentId == null) return value;
    for (final item in models) {
      if (item.value != currentId) continue;
      return item.optionById(optionId)?.labelFor(value) ?? value;
    }
    return value;
  }

  factory PeerModelsList.fromJson(Map<String, dynamic> data) {
    final raw = (data['models'] as List?) ?? const [];
    final models = raw
        .whereType<Map>()
        .map((item) => PeerAgentModel.fromJson(Map<String, dynamic>.from(item)))
        .whereType<PeerAgentModel>()
        .toList();
    final current = data['current'];
    return PeerModelsList(
      models: models,
      current: current is String ? current : null,
      switchable: data['switchable'] != false,
      optionValues: _optionValuesOf(data['option_values']),
    );
  }

  Map<String, dynamic> toJson() => {
        'models': [for (final model in models) model.toJson()],
        'current': current,
        'switchable': switchable,
        'option_values': optionValues,
      };
}

Map<String, String> _optionValuesOf(Object? raw) {
  if (raw is! Map) return const {};
  final values = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || key.isEmpty || value is! String || value.isEmpty) {
      continue;
    }
    values[key] = value;
  }
  return values;
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

  Map<String, dynamic> toJson() => {
        'value': value,
        'display_name': displayName,
        'description': description,
      };
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

  /// 非空表示宿主明确拒绝 / 出错（与超时、未发出区分）。
  final String? error;

  const PeerSoulInfo({
    required this.soul,
    required this.editable,
    this.error,
  });

  bool get isOk => error == null;

  factory PeerSoulInfo.ok({required String soul, required bool editable}) =>
      PeerSoulInfo(soul: soul, editable: editable);

  factory PeerSoulInfo.fail(String error) =>
      PeerSoulInfo(soul: '', editable: false, error: error);
}

/// Resume (bio) text + edit permission from `agent_resume_get_resp`.
class PeerResumeInfo {
  final String resume;
  final bool editable;

  /// 非空表示宿主明确拒绝 / 出错（与超时、未发出区分）。
  final String? error;

  const PeerResumeInfo({
    required this.resume,
    required this.editable,
    this.error,
  });

  bool get isOk => error == null;

  factory PeerResumeInfo.ok({required String resume, required bool editable}) =>
      PeerResumeInfo(resume: resume, editable: editable);

  factory PeerResumeInfo.fail(String error) =>
      PeerResumeInfo(resume: '', editable: false, error: error);
}

/// Result of `agent_resume_set_resp` / `agent_resume_rebuild_resp`.
class PeerResumeResult {
  final bool ok;

  /// rebuild 成功时宿主返回的新简历文本。
  final String? resume;
  final String? error;

  const PeerResumeResult({required this.ok, this.resume, this.error});
}

/// Structured memory relay result from `agent_memory_resp`.
class PeerMemoryResult {
  final bool ok;
  final bool editable;
  final List<AgentMemoryEntry> memories;
  final int? memoryId;
  final String? error;

  const PeerMemoryResult({
    required this.ok,
    this.editable = false,
    this.memories = const [],
    this.memoryId,
    this.error,
  });
}

/// One hub instance as returned by `agent_manage_resp`.
class PeerAgentManageEntry {
  final String id;
  final String name;
  final String engine;
  final String cwd;
  final bool running;
  final bool enabled;
  final bool manageable;

  const PeerAgentManageEntry({
    required this.id,
    required this.name,
    this.engine = '',
    this.cwd = '',
    required this.running,
    required this.enabled,
    required this.manageable,
  });

  factory PeerAgentManageEntry.fromJson(Map<String, dynamic> json) {
    return PeerAgentManageEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      engine: json['engine'] as String? ?? '',
      cwd: json['cwd'] as String? ?? '',
      running: json['running'] == true,
      enabled: json['enabled'] != false,
      manageable: json['manageable'] == true,
    );
  }
}

/// 引擎自己的一种会话模式。
class PeerSessionMode {
  final String value;
  final String displayName;
  final String description;

  const PeerSessionMode({
    required this.value,
    required this.displayName,
    this.description = '',
  });

  factory PeerSessionMode.fromJson(Map<String, dynamic> json) {
    final value = (json['value'] as String?)?.trim() ?? '';
    final name = (json['display_name'] as String?)?.trim() ?? '';
    return PeerSessionMode(
      value: value,
      displayName: name.isEmpty ? value : name,
      description: (json['description'] as String?)?.trim() ?? '',
    );
  }
}

/// An engine the host could launch, from `agent_manage_resp.engines`.
class PeerEngineEntry {
  final String id;
  final String name;
  final String command;

  /// Whether the engine's command is on the host's PATH.
  final bool available;

  /// 命令不在主机上时，主机给出的原因。可用时为空。
  final String unavailableReason;

  final List<PeerSessionMode> sessionModes;
  final String? defaultSessionMode;

  /// 主机下发的 SVG，标准 base64。
  final String avatarData;
  final String avatarExt;

  /// 安装和登录说明。没有文档时为空。
  final String docsUrl;

  /// 主机上实际拉起的命令。
  final String acpCommand;

  const PeerEngineEntry({
    required this.id,
    required this.name,
    this.command = '',
    required this.available,
    this.unavailableReason = '',
    this.sessionModes = const [],
    this.defaultSessionMode,
    this.avatarData = '',
    this.avatarExt = '',
    this.docsUrl = '',
    this.acpCommand = '',
  });

  factory PeerEngineEntry.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String? ?? '';
    final name = json['name'] as String?;
    final modes = <PeerSessionMode>[
      for (final item in (json['session_modes'] as List?) ?? const [])
        if (item is Map)
          PeerSessionMode.fromJson(Map<String, dynamic>.from(item)),
    ].where((mode) => mode.value.isNotEmpty).toList();
    final fallback = json['default_session_mode'] as String?;
    return PeerEngineEntry(
      id: id,
      name: name == null || name.isEmpty ? id : name,
      command: json['command'] as String? ?? '',
      available: json['available'] == true,
      unavailableReason: (json['unavailable_reason'] as String?)?.trim() ?? '',
      sessionModes: modes,
      defaultSessionMode:
          fallback == null || fallback.trim().isEmpty ? null : fallback.trim(),
      avatarData: (json['avatar_data'] as String?)?.trim() ?? '',
      avatarExt: (json['avatar_ext'] as String?)?.trim() ?? '',
      docsUrl: (json['docs_url'] as String?)?.trim() ?? '',
      acpCommand: (json['acp_command'] as String?)?.trim() ?? '',
    );
  }
}

class PeerAgentManageResult {
  final bool ok;
  final String? error;
  final List<PeerAgentManageEntry> agents;
  final List<PeerEngineEntry> engines;
  final bool unsupported;

  /// Host-side id of the agent made by `create`.
  final String? createdAgentId;

  /// Live probe of hub-local `GET /api/v1/health` (agent_manage list).
  final bool? hubStoreOk;

  /// Device id from hub store health when [hubStoreOk] is true.
  final String? hubStoreDevice;

  const PeerAgentManageResult({
    required this.ok,
    this.error,
    this.agents = const [],
    this.engines = const [],
    this.unsupported = false,
    this.createdAgentId,
    this.hubStoreOk,
    this.hubStoreDevice,
  });
}

/// Hub host directory listing from `fs_browse_resp`.
class PeerFsBrowseResult {
  final bool ok;
  final String? error;
  final String path;
  final String? parent;
  final List<({String name, String path})> entries;
  final bool unsupported;

  const PeerFsBrowseResult({
    required this.ok,
    this.error,
    this.path = '',
    this.parent,
    this.entries = const [],
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

/// Why a turn resume request is in flight — stall probes must not fail the
/// turn when the hub is slow to answer.
enum _ResumePurpose { none, suspend, stallProbe }

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

  /// SQLite id of the streaming-flush partial row backing this turn. Bridged
  /// in via [PeerAgentClientService.noteInflightPartialMessageId] so the
  /// persisted record lets a post-process-kill restore delete/reuse that exact
  /// row instead of leaving a stale half-reply next to the final message.
  String? partialMessageId;

  /// 非 null 表示该 turn 因 peer 断连而挂起，等待重连续传。
  DateTime? suspendedSince;

  /// 是否已发出 resume_req 且尚未收到应答（防止重复发送）。
  bool resumeInFlight = false;

  /// resume_req 的用途：断连续传 vs 停滞探测（后者失败不判死 turn）。
  _ResumePurpose resumePurpose = _ResumePurpose.none;

  /// 上次向 Hub 发 stall-probe resume_req 的时刻（节流重复探测）。
  DateTime? lastStallProbeAt;

  /// 最近一张审批卡到达的时刻。闸门过期后允许 stall probe。
  DateTime? lastApprovalOpenedAt;

  /// Hub 通知上游 ACP 正在重连 —— idle 计时冻结，避免 P2P 仍连着但
  /// Hub↔Agent 恢复期间误触 30min 超时。
  DateTime? upstreamReconnectingSince;

  /// 最近一次 Hub keepalive（上游仍在 working）。只推迟 idle 超时判失败，
  /// 不参与 settle / stall probe。
  DateTime? lastKeepaliveAt;

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
      partialMessageId: partialMessageId,
      startedAtMs: startedAtMs,
      updatedAtMs: now,
    );
  }
}

class _PendingFilePush {
  final Completer<void> begin = Completer<void>();

  /// Completes with host `pouch_uri` (may be null on legacy hosts).
  final Completer<String?> end = Completer<String?>();
}

class PeerAgentClientService {
  PeerAgentClientService._();
  static final PeerAgentClientService instance = PeerAgentClientService._();

  static const _tag = 'PeerAgentClient';

  /// Upper bound for a single peer agent chat request when the agent produces
  /// no output. A peer that stays connected but never answers must not hang a
  /// group orchestration forever. Each streaming chunk/metadata resets the
  /// idle clock; approval waits are uncapped — see [_awaitTurnCompletion].
  static const Duration chatTimeout = Duration(minutes: 30);

  /// 连接仍存活但距上次 agent 输出超过该时长 → 向 Hub 发
  /// `agent_turn_resume_req` 补拉（对齐直连 ACP 的 180s stall watchdog）。
  static const Duration stallProbeInterval = Duration(seconds: 180);

  /// 断连挂起（等待重连续传）的最长时长。挂起期间 idle 计时冻结（对端本来
  /// 就不可能有帧到达），超过该时长说明重连无望，判 turn 失败。
  /// 须长于 hub 的审批期限 / TURN_RESULT_TTL_MS（默认 2h）—— hub 在期限内
  /// 让 turn 继续跑并保留结果，app 先放弃会丢掉本可续传的回复。
  static const Duration suspendWaitHardCap = Duration(minutes: 150);

  /// resume_req 发出后对端无应答的容忍时长（旧版本 hub 不支持续传时
  /// 不会回复），超时按「对端不支持续传」失败，避免无限悬挂。
  static const Duration resumeResponseTimeout = Duration(seconds: 10);

  /// 单帧丢失/握手竞态导致 resume_req 石沉大海时，在判死前重发 resume_req
  /// 的次数。hub 侧应答是幂等的（drop-prefix 去重 + known 超界收敛），重发
  /// 只会补回丢失的后缀，不会重复投递。旧 hub（不支持续传）会在重试耗尽后
  /// 得到与以前一致的明确失败，只是判定延迟从 10s 放宽到 (N+1)×10s —— 远低于
  /// 30min 挂起硬顶，可接受。
  ///
  /// 背景：长任务（Claude Code 回合）跨多次重连时，重连瞬间的噪声/半开竞态会
  /// 偶发吞掉恰好那一帧 resume_req；hub 端从未收到 → 永不回复 → 原实现 10s 后
  /// 直接判死整个回合并提示「请重新发送」，即使 hub 与任务都还活着。
  static const int resumeRetryCount = 2;

  final _log = LoggerService();
  final _uuid = const Uuid();
  final _storage = PeerStorageService();
  final Map<String, Timer> _persistTimers = {};

  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  StreamSubscription<void>? _peerListSub;
  final Map<String, List<Completer<void>>> _agentListWaiters = {};
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
  final Map<String, StreamController<List<SlashCommandInfo>>>
      _slashCommandsStreams = {};

  /// Outstanding agent_sessions_req per remote agent id.
  final Map<String, Completer<List<PeerRemoteSession>>> _pendingSessions = {};

  /// Outstanding agent_session_history_req per "agentId::sessionId" key.
  /// 同一会话的分页是串行发的，所以按会话去重不会把两页混在一起。
  final Map<String, Completer<PeerHistoryPage>> _pendingHistory = {};

  /// Outstanding agent_models_req per remote agent id.
  final Map<String, Completer<PeerModelsList>> _pendingModels = {};

  /// 本次连接内已经用 agent_commands_resp 刷新过的 agent。预热进内存的旧
  /// 命令不算，否则 ensureCommandsForLocalAgent 会永远跳过网络刷新。
  final Set<String> _commandsFreshThisConnection = {};

  /// remoteAgentId → 刷新这条命令时所属的 peer，断线时按 peer 清新鲜标记。
  final Map<String, String> _commandsFreshPeer = {};

  /// agent_soul_set_req 的待写正文。响应里没有 soul 时用它更新缓存。
  final Map<String, ({String agentId, String soul})> _pendingSoulText = {};

  /// Outstanding agent_models_set_req per "agentId::model" key.
  final Map<String, Completer<({bool ok, String? error})>> _pendingModelSet =
      {};

  /// Outstanding agent_model_option_set_req per "agentId::option" key.
  final Map<String, Completer<({bool ok, String? error})>>
      _pendingModelOptionSet = {};

  /// Outstanding agent_modes_req per remote agent id.
  final Map<String, Completer<PeerModesList>> _pendingModes = {};

  /// Outstanding agent_modes_set_req per "agentId::mode" key.
  final Map<String, Completer<({bool ok, String? error})>> _pendingModeSet = {};

  /// Outstanding agent_soul_req keyed by request_id.
  final Map<String, Completer<PeerSoulInfo?>> _pendingSoulGet = {};

  /// request_id 索引：agent_id → 最新 request_id（兼容旧宿主只回 agent_id）。
  final Map<String, String> _soulGetRequestByAgent = {};

  /// Outstanding agent_soul_set_req keyed by request_id.
  final Map<String, Completer<bool>> _pendingSoulSet = {};

  /// Outstanding agent_resume_get_req keyed by request_id.
  final Map<String, Completer<PeerResumeInfo?>> _pendingResumeGet = {};

  /// Outstanding agent_resume_set_req / agent_resume_rebuild_req keyed by
  /// request_id.
  final Map<String, Completer<PeerResumeResult>> _pendingResumeSet = {};

  /// Outstanding agent_memory_req keyed by request_id.
  final Map<String, Completer<PeerMemoryResult>> _pendingMemory = {};

  /// Outstanding agent_manage_req keyed by request_id.
  final Map<String, Completer<PeerAgentManageResult>> _pendingManage = {};

  /// Outstanding fs_browse_req keyed by request_id.
  final Map<String, Completer<PeerFsBrowseResult>> _pendingFsBrowse = {};

  /// Maps hub approval_id → agent_chat request_id for deferred completion.
  final Map<String, String> _approvalToRequest = {};

  /// Approvals that arrived after agent_done already cleared `_pending`.
  /// Kept briefly so a late UI path can still surface / submit them.
  final Map<String, Map<String, dynamic>> _orphanedApprovals = {};

  /// 已成功提交的裁决（approvalId → 裁决内容）。hub 断连重连后会重发卡片；
  /// 若裁决其实已提交成功（只是 resp 没到达 hub），重发的卡片用这里存储的
  /// 裁决自动应答，不再计数、不再弹卡（E24）。
  /// 有界：超过 50 条时淘汰最旧。
  final Map<String, ({String actionId, String? label})> _submittedApprovals =
      {};

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

  /// 缓存真正写入之后发出。`kind` 用 [PeerAgentMetaKind] 的常量。
  /// 删除 agent 时按 kind 各发一条，打开着的页面就能清掉对应入口。
  /// 这是单例上的长期流，[stop] 不关闭它。
  final _metaChanged =
      StreamController<({String agentId, String kind})>.broadcast();
  Stream<({String agentId, String kind})> get metaChanged =>
      _metaChanged.stream;

  /// requestId → owning agent, retained briefly after a turn finishes so an
  /// approval that outlives its sendChat request (e.g. the hub restarted
  /// mid-approval and re-sent it after reconnect) can still be routed to the
  /// right chat screen. Bounded — oldest entries are evicted.
  final Map<String, ({String peerId, String remoteAgentId})> _requestAgents =
      {};

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

    try {
      _db.onRemoteAgentDeleted = forgetPeerAgentMeta;
    } catch (e) {
      _log.warning('peer meta forget hook skipped: $e', tag: _tag);
    }
    unawaited(_warmCommandsCache());

    _controlSub =
        PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _eventSub =
        PeerConnectionManager.instance.events.listen(_onConnectionEvent);
    _peerListSub = PeerConnectionManager.instance.peerListChanged
        .listen((_) => _reconcileDeletions());

    // resumeAll 刷新连接前会征询此钩子：有在途 turn / 待决审批的连接必须保留，
    // 否则恢复前台（尤其桌面端，连接其实仍存活）会杀死整轮交互。
    PeerConnectionManager.instance.hasInFlightTurnForPeer =
        _hasInFlightTurnForPeer;

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
    _commandsFreshThisConnection.clear();
    _commandsFreshPeer.clear();
    _pendingSoulText.clear();
    try {
      if (_db.onRemoteAgentDeleted == forgetPeerAgentMeta) {
        _db.onRemoteAgentDeleted = null;
      }
    } catch (_) {}
    PeerConnectionManager.instance.hasInFlightTurnForPeer = null;
    _controlSub?.cancel();
    _controlSub = null;
    _eventSub?.cancel();
    _eventSub = null;
    _peerListSub?.cancel();
    _peerListSub = null;
    for (final waiters in _agentListWaiters.values) {
      for (final c in waiters) {
        if (!c.isCompleted) c.complete();
      }
    }
    _agentListWaiters.clear();
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
      if (!c.isCompleted) c.complete(PeerHistoryPage.empty);
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
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModelSet.clear();
    for (final c in _pendingModelOptionSet.values) {
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModelOptionSet.clear();
    for (final c in _pendingModeSet.values) {
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModeSet.clear();
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

  /// Cancel every in-flight turn bound to [channelId], regardless of which
  /// [ACPCancellationToken] (if any) the turn was started with.
  ///
  /// User stop must not depend on the controller's token identity: after a
  /// chat-page reattach or a process restart (hydrated turns), the token that
  /// started the turn is gone, and cancelling the controller's fresh token
  /// would leave both the peer's turn and our inflight guard running —
  /// blocking the next send with "上一轮回复仍在继续" until the idle watchdog
  /// fires. Called from the DM/group stop funnels.
  Future<void> cancelInflightTurnsForChannel(String channelId) async {
    if (channelId.isEmpty) return;
    final requestIds = <String>[
      for (final entry in _pending.entries)
        if (!entry.value.completer.isCompleted &&
            entry.value.channelId == channelId)
          entry.key,
    ];
    for (final requestId in requestIds) {
      _abortPendingTurn(requestId);
    }
  }

  /// Cancel the in-flight turn of a single group agent (identified by its
  /// [localAgentId] on this device) for [channelId]. The host already aborts
  /// per `request_id` (see `_handleCancel`), so this is purely a client-side
  /// filter on top of [_abortPendingTurn] — other agents in the same group
  /// turn keep streaming.
  Future<void> cancelInflightTurnForAgent(
    String channelId,
    String localAgentId,
  ) async {
    if (channelId.isEmpty || localAgentId.isEmpty) return;
    final requestIds = <String>[
      for (final entry in _pending.entries)
        if (!entry.value.completer.isCompleted &&
            entry.value.channelId == channelId &&
            entry.value.localAgentId == localAgentId)
          entry.key,
    ];
    for (final requestId in requestIds) {
      _abortPendingTurn(requestId);
    }
  }

  /// Abort a pending turn locally and notify the peer: remove it from
  /// [_pending], complete its completer with `[Stopped]`, clear persisted
  /// state, and best-effort send `agent_cancel` so the host interrupts its
  /// side. Suspended turns are registered in [_cancelledWhileSuspended] so a
  /// reconnect re-sends cancel instead of resuming (see [_resumeSuspendedTurns]).
  void _abortPendingTurn(String requestId) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    // 断连挂起期间的取消：下面的 sendControl 大概率发不出去（连接已断），
    // 登记下来，重连后补发 cancel 而不是 resume（见 _resumeSuspendedTurns）。
    if (p.suspendedSince != null) {
      _cancelledWhileSuspended[requestId] = p.peerId;
      if (_cancelledWhileSuspended.length > 100) {
        _cancelledWhileSuspended.remove(_cancelledWhileSuspended.keys.first);
      }
    }
    for (final entry in _approvalToRequest.entries.toList()) {
      if (entry.value == requestId) {
        _approvalToRequest.remove(entry.key);
      }
    }
    _clearPersistedTurn(requestId);
    p.completer.complete(
      PeerChatResult(content: '[Stopped]', requestId: requestId),
    );
    final sendControl =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    unawaited(sendControl(p.peerId, {
      'type': 'agent_cancel',
      'request_id': requestId,
    }));
  }

  // ── Test seams ─────────────────────────────────────────────────────────

  /// Test seam: when set, [_abortPendingTurn] routes its `agent_cancel`
  /// control frame here instead of [PeerConnectionManager], letting unit
  /// tests capture frames without a live peer connection.
  @visibleForTesting
  Future<bool> Function(String peerId, Map<String, dynamic> json)?
      debugSendControlOverride;

  /// Test seam: shrink the resume-response watchdog so unit tests can observe
  /// resend/retry behavior without waiting [resumeResponseTimeout] for real.
  @visibleForTesting
  Duration? debugResumeResponseTimeoutOverride;

  /// Test seam: run the reconnect-resume sequence for [peerId] directly,
  /// without a live connection event.
  @visibleForTesting
  Future<void> debugResumeSuspendedTurns(String peerId) =>
      _resumeSuspendedTurns(peerId);

  /// Test seam: deliver a control frame as if it came from the peer
  /// connection, so unit tests can answer relay requests they captured via
  /// [debugSendControlOverride] without a live connection.
  @visibleForTesting
  void debugInjectControlForTest(
    String type,
    Map<String, dynamic> data, {
    String peerId = 'peer-test',
  }) {
    _onControl(PeerControlEvent(
      peerId: peerId,
      data: {'type': type, ...data},
    ));
  }

  /// Test seam: treat these peers as connected inside [ensureCommandsForLocalAgent].
  @visibleForTesting
  Set<String>? debugConnectedPeerIdsOverride;

  /// Test seam: shrink model/mode list timeouts.
  @visibleForTesting
  Duration? debugMetaFetchTimeoutOverride;

  /// Test seam: load persisted slash commands without the rest of [start].
  @visibleForTesting
  Future<void> debugWarmSlashCommandsForTest() => _warmCommandsCache();

  /// Test seam: deliver a connection event without a live peer.
  @visibleForTesting
  void debugInjectConnectionEvent(PeerConnectionEvent event) {
    _onConnectionEvent(event);
  }

  /// Test seam: drop in-memory meta bookkeeping so singleton tests don't leak.
  @visibleForTesting
  void debugResetPeerMetaForTest() {
    debugSendControlOverride = null;
    debugConnectedPeerIdsOverride = null;
    debugMetaFetchTimeoutOverride = null;
    _commandsCache.clear();
    _commandsFreshThisConnection.clear();
    _commandsFreshPeer.clear();
    _pendingSoulText.clear();
    for (final c in _pendingModels.values) {
      if (!c.isCompleted) c.complete(const PeerModelsList(models: []));
    }
    _pendingModels.clear();
    for (final c in _pendingModes.values) {
      if (!c.isCompleted) c.complete(const PeerModesList(modes: []));
    }
    _pendingModes.clear();
    for (final c in _pendingCommands.values) {
      if (!c.isCompleted) c.complete(const []);
    }
    _pendingCommands.clear();
    for (final c in _pendingHistory.values) {
      if (!c.isCompleted) c.complete(PeerHistoryPage.incomplete);
    }
    _pendingHistory.clear();
    for (final c in _pendingModelSet.values) {
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModelSet.clear();
    for (final c in _pendingModelOptionSet.values) {
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModelOptionSet.clear();
    for (final c in _pendingModeSet.values) {
      if (!c.isCompleted) c.complete((ok: false, error: null));
    }
    _pendingModeSet.clear();
  }

  /// Test seam: register a synthetic in-flight turn (as [sendChat] would)
  /// and return its completion future, so cancel logic can be exercised
  /// without a peer connection.
  @visibleForTesting
  Future<PeerChatResult> debugSeedPendingTurn({
    required String requestId,
    required String peerId,
    String remoteAgentId = 'remote-agent',
    String channelId = '',
    String sessionId = '',
    String localAgentId = '',
    bool suspended = false,
  }) {
    final p = _PendingRequest(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      channelId: channelId,
      sessionId: sessionId,
      localAgentId: localAgentId,
    );
    if (suspended) {
      p.suspendedSince = DateTime.now();
    }
    _pending[requestId] = p;
    return p.completer.future;
  }

  /// Test seam: read-only view of [_cancelledWhileSuspended].
  @visibleForTesting
  Map<String, String> get debugCancelledWhileSuspended =>
      Map.unmodifiable(_cancelledWhileSuspended);

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

  /// Bridge from [StreamingFlushHelper.onFlushed]: record the SQLite id of the
  /// streaming partial row so it survives process kill via the persisted
  /// inflight record (without this the field is always null after restore and
  /// the stale half-reply row can never be deleted on completion).
  void noteInflightPartialMessageId(String requestId, String messageId) {
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted) return;
    if (p.partialMessageId == messageId) return;
    p.partialMessageId = messageId;
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
      pending.partialMessageId = rec.partialMessageId;
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
      _log.warning('persist inflight $requestId failed: $e',
          tag: _tag, error: e);
    }
  }

  void _clearPersistedTurn(String requestId) {
    _persistTimers.remove(requestId)?.cancel();
    unawaited(_storage.deleteInflightTurn(requestId).catchError((Object e) {
      // 与 _persistTurnNow 对齐：持久化清理失败不影响内存态已完成的取消。
      _log.debug('clear persisted inflight $requestId failed: $e', tag: _tag);
    }));
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
      final chunkSent =
          await PeerConnectionManager.instance.sendControl(peerId, {
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
    List<Map<String, dynamic>>? history,
    List<Map<String, dynamic>>? extraTools,
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

    cancelToken?.addOnCancelled(() => _abortPendingTurn(requestId));

    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_chat',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'message': message,
      // 把本端会话 id 透传给对端，使对端按会话隔离历史：本端「新开会话」
      // 在对端也得到一条干净、无历史的新会话。
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (history != null && history.isNotEmpty) 'history': history,
      if (attachmentRefs != null) 'attachments': attachmentRefs,
      if (extraTools != null && extraTools.isNotEmpty)
        'extra_tools': extraTools,
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
  /// count against the turn. Approval waits are uncapped — the turn stays
  /// open until the user decides (or the remote side closes it).
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
      final now = DateTime.now();
      final verdict = evaluateTurnWatchdog(
        now: now,
        startedAt: startedAt,
        idleSince: pending.idleSince,
        suspendedSince: pending.suspendedSince,
        upstreamReconnectingSince: pending.upstreamReconnectingSince,
        openApprovals: pending.openApprovals,
        chatTimeout: chatTimeout,
        suspendWaitHardCap: suspendWaitHardCap,
        lastKeepaliveAt: pending.lastKeepaliveAt,
      );
      if (verdict != TurnWatchdogVerdict.none) {
        timer.cancel();
        _timeoutRequest(
          requestId,
          peerId,
          duringApproval: pending.openApprovals > 0,
          duringSuspend: verdict == TurnWatchdogVerdict.suspendCap,
        );
        return;
      }
      if (shouldCompleteSettledReply(
        now: now,
        idleSince: pending.idleSince,
        suspendedSince: pending.suspendedSince,
        upstreamReconnectingSince: pending.upstreamReconnectingSince,
        openApprovals: pending.openApprovals,
        hasAssistantContent: pending.answerContent.trim().isNotEmpty,
      )) {
        timer.cancel();
        _log.info(
          'reply settled requestId=$requestId '
          '(${pending.answerContent.length} chars, no agent_done needed)',
          tag: _tag,
        );
        _finishPending(requestId, {'content': pending.answerContent});
        return;
      }
      if (shouldProbeStalledTurn(
        now: now,
        idleSince: pending.idleSince,
        suspendedSince: pending.suspendedSince,
        upstreamReconnectingSince: pending.upstreamReconnectingSince,
        openApprovals: pending.openApprovals,
        resumeInFlight: pending.resumeInFlight,
        lastStallProbeAt: pending.lastStallProbeAt,
        stallProbeInterval: stallProbeInterval,
        lastApprovalOpenedAt: pending.lastApprovalOpenedAt,
      )) {
        unawaited(_probeStalledTurn(requestId, peerId, pending));
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
    // 提示原本只在下一个 connected 事件投递；但判死恰恰常发生在连接已恢复
    // 之后（resumeAll 对在途 turn 保留连接不重建 → 之后可能再无 connected
    // 事件；或 resume 应答 lost 时连接早已在位），提示会一直压在队列里，
    // 结果永久留在远端 transcript。连接已在位就立刻补发一次。
    if (PeerConnectionManager.instance.connectedPeerIds
        .contains(owner.peerId)) {
      scheduleMicrotask(() => _flushReconcileHints(owner.peerId));
    }
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
      case 'pouch_turn_event':
        PouchTurnRelay.instance.onEvent(event.data);
        break;
      case 'pouch_file_ack':
        PouchTurnRelay.instance.onFileAck(event.data);
        break;
      case 'pouch_pair_resp':
      case 'pouch_peer_list_resp':
        PouchPairRelay.instance.onResponse(event.data);
        break;
      case 'agent_turn_resume_resp':
        _onTurnResumeResp(event.data);
        break;
      case 'agent_turn_upstream_reconnecting':
        _onUpstreamReconnecting(event.data);
        break;
      case 'agent_turn_upstream_reconnected':
        _onUpstreamReconnected(event.data);
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
      case 'session_create_req':
        unawaited(_onSessionCreateReq(event.peerId, event.data));
        break;
      case 'cli_execute_req':
        unawaited(_onCliExecuteReq(event.peerId, event.data));
        break;
      case 'agent_commands_resp':
        _onCommandsResp(event.peerId, event.data);
        break;
      case 'agent_meta_changed':
        _onAgentMetaChanged(event);
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
      case 'agent_model_option_set_resp':
        _onModelOptionSetResp(event.data);
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
      case 'agent_resume_get_resp':
        _onResumeResp(event.data);
        break;
      case 'agent_resume_set_resp':
      case 'agent_resume_rebuild_resp':
        _onResumeSetResp(event.data);
        break;
      case 'agent_memory_resp':
        _onMemoryResp(event.data);
        break;
      case 'agent_manage_resp':
        _onManageResp(event.data);
        break;
      case 'fs_browse_resp':
        _onFsBrowseResp(event.data);
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
    final storeUri = data['pouch_uri'] as String?;

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

  Duration get _metaListTimeout =>
      debugMetaFetchTimeoutOverride ?? const Duration(seconds: 15);

  Future<bool> _sendMetaControl(String peerId, Map<String, dynamic> json) {
    final send =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    return send(peerId, json);
  }

  /// 从没缓存过返回 null；空列表表示对端明确不支持。
  Future<PeerModelsList?> cachedModels(String localAgentId) =>
      _readCachedModels(localAgentId);

  Future<PeerModesList?> cachedModes(String localAgentId) =>
      _readCachedModes(localAgentId);

  Future<PeerSoulInfo?> cachedSoul(String localAgentId) =>
      _readCachedSoul(localAgentId);

  /// Fetch upstream model options (`agent.models.list` relay). Returns empty
  /// list on failure/timeout. [sessionId] is the bare remote session id when
  /// scoping to a synced session; omit for the agent default.
  ///
  /// 缓存只记 agent 级。Hub 目前忽略请求里的 session_id。
  Future<PeerModelsList> fetchModels({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    final outcome = await fetchModelsResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: sessionId,
    );
    return outcome.list;
  }

  /// 与 [fetchModels] 相同，但用 [completed] 区分「对端回答了」和超时 / 没发出。
  Future<({PeerModelsList list, bool completed})> fetchModelsResult({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    final existing = _pendingModels[remoteAgentId];
    if (existing != null) {
      try {
        final list = await existing.future.timeout(_metaListTimeout);
        return (list: list, completed: true);
      } on TimeoutException {
        return (list: const PeerModelsList(models: []), completed: false);
      }
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
    final sent = await _sendMetaControl(peerId, payload);
    if (!sent) {
      if (identical(_pendingModels[remoteAgentId], completer)) {
        _pendingModels.remove(remoteAgentId);
      }
      return (list: const PeerModelsList(models: []), completed: false);
    }
    try {
      final list = await completer.future.timeout(_metaListTimeout);
      return (list: list, completed: true);
    } on TimeoutException {
      if (identical(_pendingModels[remoteAgentId], completer)) {
        _pendingModels.remove(remoteAgentId);
      }
      return (list: const PeerModelsList(models: []), completed: false);
    }
  }

  void _onModelsResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final list = _parseModelsData(data);
    if (_isAgentLevelMeta(data)) {
      _rememberModels(remoteId, list, rev: _nonEmpty(data['rev']));
    }
    final completer = _pendingModels.remove(remoteId);
    if (completer != null && !completer.isCompleted) completer.complete(list);
  }

  /// Switch the upstream model (`agent.models.setCurrent` relay).
  Future<bool> setModel({
    required String peerId,
    required String remoteAgentId,
    required String model,
    String? sessionId,
  }) async {
    final result = await setModelResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      model: model,
      sessionId: sessionId,
    );
    return result.ok;
  }

  /// 与 [setModel] 相同，但带回 Hub 的 `error`（例如 `not_switchable`）。
  Future<({bool ok, String? error})> setModelResult({
    required String peerId,
    required String remoteAgentId,
    required String model,
    String? sessionId,
  }) async {
    final key = '$remoteAgentId::$model';
    final existing = _pendingModelSet[key];
    if (existing != null) return existing.future;
    final completer = Completer<({bool ok, String? error})>();
    _pendingModelSet[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_models_set_req',
      'agent_id': remoteAgentId,
      'model': model,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await _sendMetaControl(peerId, payload);
    if (!sent) {
      _pendingModelSet.remove(key);
      return (ok: false, error: null);
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModelSet.remove(key);
      return (ok: false, error: null);
    });
  }

  void _onModelsSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final model = data['model'] as String?;
    if (remoteId == null || model == null) return;
    final ok = data['ok'] == true;
    final error = _nonEmpty(data['error']);
    final completer = _pendingModelSet.remove('$remoteId::$model');
    if (completer != null && !completer.isCompleted) {
      completer.complete((ok: ok, error: error));
    }
    if (ok) {
      _patchCachedCurrent(remoteId, PeerAgentMetaKind.models, model);
    } else if (error == 'not_switchable') {
      _patchCachedSwitchable(remoteId, PeerAgentMetaKind.models, false);
    }
  }

  /// 设置 Agent 级模型参数（目前只有 Cursor 的 `fast`）。
  /// [value] 为 `true` / `false`，空字符串表示清掉覆盖、回到模型默认值。
  Future<({bool ok, String? error})> setModelOptionResult({
    required String peerId,
    required String remoteAgentId,
    required String option,
    required String value,
    String? sessionId,
  }) async {
    final key = '$remoteAgentId::$option';
    final existing = _pendingModelOptionSet[key];
    if (existing != null) return existing.future;
    final completer = Completer<({bool ok, String? error})>();
    _pendingModelOptionSet[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_model_option_set_req',
      'agent_id': remoteAgentId,
      'option': option,
      'value': value,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await _sendMetaControl(peerId, payload);
    if (!sent) {
      _pendingModelOptionSet.remove(key);
      return (ok: false, error: null);
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModelOptionSet.remove(key);
      return (ok: false, error: null);
    });
  }

  void _onModelOptionSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final option = data['option'] as String?;
    if (remoteId == null || option == null || option.isEmpty) return;
    final rawValue = data['value'];
    final value = rawValue is String ? rawValue : '';
    final ok = data['ok'] == true;
    final error = _nonEmpty(data['error']);
    final completer = _pendingModelOptionSet.remove('$remoteId::$option');
    if (completer != null && !completer.isCompleted) {
      completer.complete((ok: ok, error: error));
    }
    if (ok) _patchCachedOptionValue(remoteId, option, value);
  }

  /// Fetch upstream session modes (`agent.modes.list` relay). Returns empty
  /// list on failure/timeout. [sessionId] scopes to a synced session.
  Future<PeerModesList> fetchModes({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    final outcome = await fetchModesResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: sessionId,
    );
    return outcome.list;
  }

  /// 与 [fetchModes] 相同，但用 [completed] 区分「对端回答了」和超时 / 没发出。
  Future<({PeerModesList list, bool completed})> fetchModesResult({
    required String peerId,
    required String remoteAgentId,
    String? sessionId,
  }) async {
    final existing = _pendingModes[remoteAgentId];
    if (existing != null) {
      try {
        final list = await existing.future.timeout(_metaListTimeout);
        return (list: list, completed: true);
      } on TimeoutException {
        return (list: const PeerModesList(modes: []), completed: false);
      }
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
    final sent = await _sendMetaControl(peerId, payload);
    if (!sent) {
      if (identical(_pendingModes[remoteAgentId], completer)) {
        _pendingModes.remove(remoteAgentId);
      }
      return (list: const PeerModesList(modes: []), completed: false);
    }
    try {
      final list = await completer.future.timeout(_metaListTimeout);
      return (list: list, completed: true);
    } on TimeoutException {
      if (identical(_pendingModes[remoteAgentId], completer)) {
        _pendingModes.remove(remoteAgentId);
      }
      return (list: const PeerModesList(modes: []), completed: false);
    }
  }

  void _onModesResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final list = _parseModesData(data);
    if (_isAgentLevelMeta(data)) {
      _rememberModes(remoteId, list, rev: _nonEmpty(data['rev']));
    }
    final completer = _pendingModes.remove(remoteId);
    if (completer != null && !completer.isCompleted) completer.complete(list);
  }

  /// Switch the upstream session mode (`agent.modes.setCurrent` relay).
  Future<bool> setMode({
    required String peerId,
    required String remoteAgentId,
    required String mode,
    String? sessionId,
  }) async {
    final result = await setModeResult(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      mode: mode,
      sessionId: sessionId,
    );
    return result.ok;
  }

  /// 与 [setMode] 相同，但带回 Hub 的 `error`（例如 `unknown_mode`）。
  Future<({bool ok, String? error})> setModeResult({
    required String peerId,
    required String remoteAgentId,
    required String mode,
    String? sessionId,
  }) async {
    final key = '$remoteAgentId::$mode';
    final existing = _pendingModeSet[key];
    if (existing != null) return existing.future;
    final completer = Completer<({bool ok, String? error})>();
    _pendingModeSet[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_modes_set_req',
      'agent_id': remoteAgentId,
      'mode': mode,
    };
    if (sessionId != null && sessionId.isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    final sent = await _sendMetaControl(peerId, payload);
    if (!sent) {
      _pendingModeSet.remove(key);
      return (ok: false, error: null);
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingModeSet.remove(key);
      return (ok: false, error: null);
    });
  }

  void _onModesSetResp(Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    final mode = data['mode'] as String?;
    if (remoteId == null || mode == null) return;
    final ok = data['ok'] == true;
    final error = _nonEmpty(data['error']);
    final completer = _pendingModeSet.remove('$remoteId::$mode');
    if (completer != null && !completer.isCompleted) {
      completer.complete((ok: ok, error: error));
    }
    if (ok) _patchCachedCurrent(remoteId, PeerAgentMetaKind.modes, mode);
  }

  static const _soulRelayTimeout = Duration(seconds: 12);

  void _completeSoulGet(String requestId, PeerSoulInfo? info) {
    final pending = _pendingSoulGet.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(info);
    }
    _soulGetRequestByAgent.removeWhere((_, id) => id == requestId);
  }

  /// Fetch soul from a shared peer agent (`agent_soul_req` relay).
  ///
  /// 成功：`isOk == true`；宿主拒绝：`error` 有值；超时/未发出：返回 `null`。
  Future<PeerSoulInfo?> fetchSoulInfo({
    required String peerId,
    required String remoteAgentId,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerSoulInfo?>();
    _pendingSoulGet[requestId] = completer;
    _soulGetRequestByAgent[remoteAgentId] = requestId;
    _log.info(
      'agent_soul_req peer=$peerId agent=$remoteAgentId req=$requestId',
      tag: _tag,
    );
    try {
      final sent = await _sendMetaControl(peerId, {
        'type': 'agent_soul_req',
        'agent_id': remoteAgentId,
        'request_id': requestId,
      }).timeout(const Duration(seconds: 5));
      if (!sent) {
        _completeSoulGet(requestId, null);
        return null;
      }
      return await completer.future.timeout(_soulRelayTimeout);
    } on TimeoutException {
      _log.warning(
        'agent_soul_req timeout peer=$peerId agent=$remoteAgentId req=$requestId',
        tag: _tag,
      );
      _completeSoulGet(requestId, null);
      return null;
    } catch (e) {
      _log.warning('agent_soul_req failed: $e', tag: _tag);
      _completeSoulGet(requestId, null);
      return null;
    }
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
    if (info == null || !info.isOk) return null;
    return info.soul;
  }

  void _onSoulResp(Map<String, dynamic> data) {
    try {
      final requestId = data['request_id']?.toString();
      final remoteId = data['agent_id']?.toString();
      final info = _parseSoulData(data);
      if (!info.isOk) {
        _log.warning(
          'agent_soul_resp ok=false agent=$remoteId error=${info.error} req=$requestId',
          tag: _tag,
        );
      }

      if (info.isOk) {
        final agentId = (remoteId != null && remoteId.isNotEmpty)
            ? remoteId
            : _agentIdForSoulRequest(requestId);
        if (agentId != null) {
          _rememberSoul(
            agentId,
            info.soul,
            info.editable,
            rev: _nonEmpty(data['rev']),
          );
        }
      }

      if (requestId != null && requestId.isNotEmpty) {
        _completeSoulGet(requestId, info);
        return;
      }
      // 旧宿主无 request_id：按 agent_id 找回对应请求。
      if (remoteId != null && remoteId.isNotEmpty) {
        final mapped = _soulGetRequestByAgent.remove(remoteId);
        if (mapped != null) {
          _completeSoulGet(mapped, info);
          return;
        }
      }
      final match = _pendingSoulGet.entries.toList();
      if (match.isNotEmpty) {
        _completeSoulGet(match.first.key, info);
      }
    } catch (e) {
      _log.warning('agent_soul_resp parse failed: $e', tag: _tag);
    }
  }

  void _completeSoulSet(String requestId, bool ok) {
    final pending = _pendingSoulSet.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(ok);
    }
  }

  /// Update soul on a shared peer agent when host allows it.
  Future<bool> setSoul({
    required String peerId,
    required String remoteAgentId,
    required String soul,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _pendingSoulSet[requestId] = completer;
    _pendingSoulText[requestId] = (agentId: remoteAgentId, soul: soul);
    try {
      final sent = await _sendMetaControl(peerId, {
        'type': 'agent_soul_set_req',
        'agent_id': remoteAgentId,
        'soul': soul,
        'request_id': requestId,
      }).timeout(const Duration(seconds: 5));
      if (!sent) {
        _pendingSoulText.remove(requestId);
        _completeSoulSet(requestId, false);
        return false;
      }
      return await completer.future.timeout(_soulRelayTimeout);
    } on TimeoutException {
      _pendingSoulText.remove(requestId);
      _completeSoulSet(requestId, false);
      return false;
    } catch (e) {
      _log.warning('agent_soul_set_req failed: $e', tag: _tag);
      _pendingSoulText.remove(requestId);
      _completeSoulSet(requestId, false);
      return false;
    }
  }

  void _onSoulSetResp(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString();
    final ok = data['ok'] == true;
    final pending = _takePendingSoulText(
      requestId != null && requestId.isNotEmpty ? requestId : null,
      agentId: _nonEmpty(data['agent_id']),
    );
    if (ok) {
      final agentId = _nonEmpty(data['agent_id']) ?? pending?.agentId;
      final soul =
          data['soul'] is String ? data['soul'] as String : pending?.soul;
      if (agentId != null && soul != null) {
        _rememberSoul(agentId, soul, true, rev: _nonEmpty(data['rev']));
      }
    }
    if (requestId != null && requestId.isNotEmpty) {
      _completeSoulSet(requestId, ok);
      return;
    }
    final match = _pendingSoulSet.entries.toList();
    for (final e in match) {
      _completeSoulSet(e.key, ok);
      break;
    }
  }

  String? _nonEmpty(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  String? _agentIdForSoulRequest(String? requestId) {
    if (requestId == null || requestId.isEmpty) return null;
    for (final entry in _soulGetRequestByAgent.entries) {
      if (entry.value == requestId) return entry.key;
    }
    return null;
  }

  ({String agentId, String soul})? _takePendingSoulText(
    String? requestId, {
    String? agentId,
  }) {
    if (requestId != null && requestId.isNotEmpty) {
      return _pendingSoulText.remove(requestId);
    }
    if (agentId != null && agentId.isNotEmpty) {
      String? match;
      for (final entry in _pendingSoulText.entries) {
        if (entry.value.agentId == agentId) {
          match = entry.key;
          break;
        }
      }
      if (match != null) return _pendingSoulText.remove(match);
    }
    if (_pendingSoulText.isEmpty) return null;
    final key = _pendingSoulText.keys.first;
    return _pendingSoulText.remove(key);
  }

  /// `scope` 缺省或 `"agent"` 才写 agent 级缓存。`"session"` 留给以后的按会话模式。
  bool _isAgentLevelMeta(Map<String, dynamic> data) {
    final scope = data['scope'];
    if (scope == null) return true;
    if (scope is! String || scope.isEmpty) return true;
    return scope == 'agent';
  }

  PeerModelsList _parseModelsData(Map<String, dynamic> data) =>
      PeerModelsList.fromJson(data);

  PeerModesList _parseModesData(Map<String, dynamic> data) {
    final raw = (data['modes'] as List?) ?? const [];
    final modes = <PeerAgentMode>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final parsed = PeerAgentMode.fromJson(Map<String, dynamic>.from(item));
      if (parsed != null) modes.add(parsed);
    }
    final current = data['current'];
    return PeerModesList(
      modes: modes,
      current: current is String ? current : null,
    );
  }

  /// `exists: false` 是合法的空灵魂。`ok: false` 不写缓存。
  PeerSoulInfo _parseSoulData(Map<String, dynamic> data) {
    if (data['exists'] == false && data['ok'] != false) {
      return PeerSoulInfo.ok(
        soul: '',
        editable: data['editable'] == true,
      );
    }
    if (data['ok'] == true) {
      final soul = data['soul'];
      return PeerSoulInfo.ok(
        soul: soul is String ? soul : '',
        editable: data['editable'] == true,
      );
    }
    return PeerSoulInfo.fail(data['error']?.toString() ?? 'unknown');
  }

  List<SlashCommandInfo> _parseCommandList(Object? raw) {
    final commands = <SlashCommandInfo>[];
    if (raw is! List) return commands;
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        commands.add(
          SlashCommandInfo.fromJson(Map<String, dynamic>.from(item)),
        );
      } catch (_) {}
    }
    return commands;
  }

  void _onAgentMetaChanged(PeerControlEvent event) {
    final frame = event.data;
    final agentId = frame['agent_id']?.toString();
    final kind = frame['kind']?.toString();
    if (agentId == null || agentId.isEmpty || kind == null || kind.isEmpty) {
      return;
    }
    final body = frame['data'];
    if (body is! Map) {
      _log.debug('agent_meta_changed missing data kind=$kind', tag: _tag);
      return;
    }
    final data = Map<String, dynamic>.from(body);
    final rev = _nonEmpty(frame['rev']);
    switch (kind) {
      case PeerAgentMetaKind.models:
        if (!_isAgentLevelMeta(data)) return;
        _rememberModels(agentId, _parseModelsData(data), rev: rev);
      case PeerAgentMetaKind.modes:
        if (!_isAgentLevelMeta(data)) return;
        _rememberModes(agentId, _parseModesData(data), rev: rev);
      case PeerAgentMetaKind.soul:
        final info = _parseSoulData(data);
        if (!info.isOk) return;
        _rememberSoul(agentId, info.soul, info.editable, rev: rev);
      case PeerAgentMetaKind.commands:
        _applyCommandsResp(
          agentId,
          _parseCommandList(data['commands']),
          peerId: event.peerId,
          completePending: false,
          rev: rev,
        );
      default:
        _log.debug('ignore agent_meta_changed kind=$kind', tag: _tag);
    }
  }

  void _rememberModels(String agentId, PeerModelsList list, {String? rev}) {
    _writeMeta(
      agentId: agentId,
      kind: PeerAgentMetaKind.models,
      payload: {
        ...list.toJson(),
        if (rev != null && rev.isNotEmpty) 'rev': rev,
      },
    );
  }

  void _rememberModes(String agentId, PeerModesList list, {String? rev}) {
    _writeMeta(
      agentId: agentId,
      kind: PeerAgentMetaKind.modes,
      payload: {
        'modes': [for (final mode in list.modes) mode.toJson()],
        'current': list.current,
        if (rev != null && rev.isNotEmpty) 'rev': rev,
      },
    );
  }

  void _rememberSoul(
    String agentId,
    String soul,
    bool editable, {
    String? rev,
  }) {
    _writeMeta(
      agentId: agentId,
      kind: PeerAgentMetaKind.soul,
      payload: {
        'soul': soul,
        'editable': editable,
        if (rev != null && rev.isNotEmpty) 'rev': rev,
      },
    );
  }

  void _rememberCommands(
    String agentId,
    List<SlashCommandInfo> commands, {
    String? rev,
  }) {
    _writeMeta(
      agentId: agentId,
      kind: PeerAgentMetaKind.commands,
      payload: {
        'commands': [for (final command in commands) command.toJson()],
        if (rev != null && rev.isNotEmpty) 'rev': rev,
      },
    );
  }

  void _patchCachedCurrent(String agentId, String kind, String current) {
    unawaited(() async {
      try {
        final row = await _db.getPeerAgentMeta(agentId, kind);
        if (row == null) return;
        final payload = Map<String, dynamic>.from(row.payload);
        payload['current'] = current;
        await _db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
          agentId: agentId,
          kind: kind,
          payload: payload,
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        _emitMetaChanged(agentId, kind);
      } catch (e) {
        _log.warning('peer meta current update failed: $e', tag: _tag);
      }
    }());
  }

  void _patchCachedOptionValue(String agentId, String option, String value) {
    unawaited(() async {
      try {
        final row =
            await _db.getPeerAgentMeta(agentId, PeerAgentMetaKind.models);
        if (row == null) return;
        final payload = Map<String, dynamic>.from(row.payload);
        final raw = payload['option_values'];
        final values =
            raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
        if (value.isEmpty) {
          values.remove(option);
        } else {
          values[option] = value;
        }
        payload['option_values'] = values;
        await _db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
          agentId: agentId,
          kind: PeerAgentMetaKind.models,
          payload: payload,
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        _emitMetaChanged(agentId, PeerAgentMetaKind.models);
      } catch (e) {
        _log.warning('peer meta option update failed: $e', tag: _tag);
      }
    }());
  }

  void _patchCachedSwitchable(String agentId, String kind, bool switchable) {
    unawaited(() async {
      try {
        final row = await _db.getPeerAgentMeta(agentId, kind);
        if (row == null) return;
        final payload = Map<String, dynamic>.from(row.payload);
        payload['switchable'] = switchable;
        await _db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
          agentId: agentId,
          kind: kind,
          payload: payload,
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        _emitMetaChanged(agentId, kind);
      } catch (e) {
        _log.warning('peer meta switchable update failed: $e', tag: _tag);
      }
    }());
  }

  void _emitMetaChanged(String agentId, String kind) {
    if (_metaChanged.isClosed) return;
    _metaChanged.add((agentId: agentId, kind: kind));
  }

  void _writeMeta({
    required String agentId,
    required String kind,
    required Map<String, dynamic> payload,
  }) {
    unawaited(() async {
      try {
        final existing = await _db.getPeerAgentMeta(agentId, kind);
        final nextRev = payload['rev'];
        final prevRev = existing?.payload['rev'];
        if (nextRev is String &&
            nextRev.isNotEmpty &&
            prevRev is String &&
            prevRev.isNotEmpty &&
            nextRev == prevRev) {
          return;
        }
        await _db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
          agentId: agentId,
          kind: kind,
          payload: payload,
          fetchedAt: DateTime.now().millisecondsSinceEpoch,
        ));
        _emitMetaChanged(agentId, kind);
      } catch (e) {
        _log.warning('peer meta cache write failed: $e', tag: _tag);
      }
    }());
  }

  Future<PeerModelsList?> _readCachedModels(String agentId) async {
    try {
      final row = await _db.getPeerAgentMeta(agentId, PeerAgentMetaKind.models);
      if (row == null) return null;
      if (row.payload['models'] is! List) return null;
      return PeerModelsList.fromJson(row.payload);
    } catch (e) {
      _log.warning('read models cache failed: $e', tag: _tag);
      return null;
    }
  }

  Future<PeerModesList?> _readCachedModes(String agentId) async {
    try {
      final row = await _db.getPeerAgentMeta(agentId, PeerAgentMetaKind.modes);
      if (row == null) return null;
      final raw = row.payload['modes'];
      if (raw is! List) return null;
      final modes = <PeerAgentMode>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final parsed = PeerAgentMode.fromJson(Map<String, dynamic>.from(item));
        if (parsed != null) modes.add(parsed);
      }
      final current = row.payload['current'];
      return PeerModesList(
        modes: modes,
        current: current is String ? current : null,
      );
    } catch (e) {
      _log.warning('read modes cache failed: $e', tag: _tag);
      return null;
    }
  }

  Future<PeerSoulInfo?> _readCachedSoul(String agentId) async {
    try {
      final row = await _db.getPeerAgentMeta(agentId, PeerAgentMetaKind.soul);
      if (row == null) return null;
      final soul = row.payload['soul'];
      if (soul is! String) return null;
      return PeerSoulInfo.ok(
        soul: soul,
        editable: row.payload['editable'] == true,
      );
    } catch (e) {
      _log.warning('read soul cache failed: $e', tag: _tag);
      return null;
    }
  }

  Future<void> _warmCommandsCache() async {
    try {
      final rows = await _db.getAllPeerAgentMeta(PeerAgentMetaKind.commands);
      for (final row in rows) {
        final commands = _parseCachedCommands(row.payload);
        if (commands == null) continue;
        _commandsCache[row.agentId] = commands;
        final stream = _slashCommandsStreams[row.agentId];
        if (stream != null && !stream.isClosed) {
          stream.add(List.unmodifiable(commands));
        }
      }
    } catch (e) {
      _log.warning('warm slash commands failed: $e', tag: _tag);
    }
  }

  List<SlashCommandInfo>? _parseCachedCommands(Map<String, dynamic> payload) {
    final raw = payload['commands'];
    if (raw is! List) return null;
    final commands = <SlashCommandInfo>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        commands.add(
          SlashCommandInfo.fromJson(Map<String, dynamic>.from(item)),
        );
      } catch (_) {}
    }
    return commands;
  }

  /// 删掉 agent 时清内存里的斜杠命令，并通知已打开的 `/` 面板。
  /// 同时按 kind 各发一条 [metaChanged]，让还停在页面上的入口一起清掉。
  @visibleForTesting
  void forgetPeerAgentMeta(String agentId) {
    _commandsCache.remove(agentId);
    _commandsFreshThisConnection.remove(agentId);
    _commandsFreshPeer.remove(agentId);
    final stream = _slashCommandsStreams[agentId];
    if (stream != null && !stream.isClosed) {
      stream.add(const []);
    }
    _emitMetaChanged(agentId, PeerAgentMetaKind.models);
    _emitMetaChanged(agentId, PeerAgentMetaKind.modes);
    _emitMetaChanged(agentId, PeerAgentMetaKind.soul);
    _emitMetaChanged(agentId, PeerAgentMetaKind.commands);
  }

  void _dropFreshCommands(String peerId) {
    final stale = [
      for (final entry in _commandsFreshPeer.entries)
        if (entry.value == peerId) entry.key,
    ];
    for (final id in stale) {
      _commandsFreshThisConnection.remove(id);
      _commandsFreshPeer.remove(id);
    }
  }

  // ==================== Peer 简历中继 ====================

  /// 简历中继超时：带提示词时会走宿主的一次完整 AI 改写（写 Summary 前先重扫工作区，
  /// 单次 LLM 回合最长 180s），远长于 soul 的 12s。留出余量给往返。
  static const _resumeRebuildRelayTimeout = Duration(seconds: 240);

  /// 经测试 seam（若有）或连接管理器发出控制帧。
  Future<bool> _sendResumeControl(
    String peerId,
    Map<String, dynamic> json,
  ) {
    final sendControl =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    return sendControl(peerId, json);
  }

  void _completeResumeGet(String requestId, PeerResumeInfo? info) {
    final pending = _pendingResumeGet.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(info);
    }
  }

  void _completeResumeSet(String requestId, PeerResumeResult result) {
    final pending = _pendingResumeSet.remove(requestId);
    if (pending != null && !pending.isCompleted) {
      pending.complete(result);
    }
  }

  /// Fetch resume (bio) + edit permission from a shared peer agent
  /// (`agent_resume_get_req` relay).
  ///
  /// 成功：`isOk == true`；宿主拒绝：`error` 有值；超时/未发出：返回 `null`。
  Future<PeerResumeInfo?> getResumeInfo({
    required String peerId,
    required String remoteAgentId,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerResumeInfo?>();
    _pendingResumeGet[requestId] = completer;
    _log.info(
      'agent_resume_get_req peer=$peerId agent=$remoteAgentId req=$requestId',
      tag: _tag,
    );
    try {
      final sent = await _sendResumeControl(peerId, {
        'type': 'agent_resume_get_req',
        'agent_id': remoteAgentId,
        'request_id': requestId,
      }).timeout(const Duration(seconds: 5));
      if (!sent) {
        _completeResumeGet(requestId, null);
        return null;
      }
      return await completer.future.timeout(_soulRelayTimeout);
    } on TimeoutException {
      _log.warning(
        'agent_resume_get_req timeout peer=$peerId agent=$remoteAgentId req=$requestId',
        tag: _tag,
      );
      _completeResumeGet(requestId, null);
      return null;
    } catch (e) {
      _log.warning('agent_resume_get_req failed: $e', tag: _tag);
      _completeResumeGet(requestId, null);
      return null;
    }
  }

  /// Update resume on a shared peer agent when host allows it.
  /// 失败（拒绝 / 中继超时 / 未发出）返回 false，与 [setSoul] 一致。
  Future<bool> setResume({
    required String peerId,
    required String remoteAgentId,
    required String resume,
  }) async {
    try {
      final result = await _sendResumeMutation(
        type: 'agent_resume_set_req',
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        extra: {'resume': resume},
        timeout: _soulRelayTimeout,
      );
      return result.ok;
    } catch (_) {
      return false;
    }
  }

  /// Ask the host to regenerate the resume with [prompt] on its own LLM.
  ///
  /// 成功返回宿主已落库的新简历文本；失败抛 [StateError]（含宿主错误码），
  /// 超时抛 [TimeoutException]。
  Future<String> rebuildResumeViaPeer({
    required String peerId,
    required String remoteAgentId,
    required String prompt,
  }) async {
    final result = await _sendResumeMutation(
      type: 'agent_resume_rebuild_req',
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      extra: {'prompt': prompt},
      timeout: _resumeRebuildRelayTimeout,
    );
    if (!result.ok) {
      throw StateError(result.error ?? 'resume rebuild failed');
    }
    return result.resume ?? '';
  }

  Future<PeerResumeResult> _sendResumeMutation({
    required String type,
    required String peerId,
    required String remoteAgentId,
    required Map<String, String> extra,
    required Duration timeout,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerResumeResult>();
    _pendingResumeSet[requestId] = completer;
    try {
      final sent = await _sendResumeControl(peerId, {
        'type': type,
        'agent_id': remoteAgentId,
        ...extra,
        'request_id': requestId,
      }).timeout(const Duration(seconds: 5));
      if (!sent) {
        return const PeerResumeResult(ok: false, error: 'send_failed');
      }
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _completeResumeSet(
        requestId,
        const PeerResumeResult(ok: false, error: 'timeout'),
      );
      rethrow;
    } catch (e) {
      _log.warning('$type failed: $e', tag: _tag);
      _completeResumeSet(
        requestId,
        PeerResumeResult(ok: false, error: e.toString()),
      );
      rethrow;
    }
  }

  void _onResumeResp(Map<String, dynamic> data) {
    try {
      final requestId = data['request_id']?.toString();
      final PeerResumeInfo info;
      if (data['ok'] == true) {
        info = PeerResumeInfo.ok(
          resume: data['resume'] as String? ?? '',
          editable: data['editable'] == true,
        );
      } else {
        final err = data['error']?.toString() ?? 'unknown';
        _log.warning(
          'agent_resume_get_resp ok=false agent=${data['agent_id']} error=$err',
          tag: _tag,
        );
        info = PeerResumeInfo.fail(err);
      }
      if (requestId != null && requestId.isNotEmpty) {
        _completeResumeGet(requestId, info);
        return;
      }
      final match = _pendingResumeGet.entries.toList();
      if (match.isNotEmpty) {
        _completeResumeGet(match.first.key, info);
      }
    } catch (e) {
      _log.warning('agent_resume_get_resp parse failed: $e', tag: _tag);
    }
  }

  void _onResumeSetResp(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString();
    if (requestId == null || requestId.isEmpty) return;
    final ok = data['ok'] == true;
    _completeResumeSet(
      requestId,
      PeerResumeResult(
        ok: ok,
        resume: data['resume'] as String?,
        error: ok ? null : (data['error']?.toString() ?? 'unknown'),
      ),
    );
  }

  /// Relay structured memory CRUD to the host agent's store directory.
  Future<PeerMemoryResult> memoryOp({
    required String peerId,
    required String remoteAgentId,
    required String op,
    MemoryType? type,
    String? keyword,
    int? limit,
    AgentMemoryEntry? entry,
    int? memoryId,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerMemoryResult>();
    _pendingMemory[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_memory_req',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'op': op,
      if (type != null) 'type': type.name,
      if (keyword != null) 'keyword': keyword,
      if (limit != null) 'limit': limit,
      if (entry != null) 'entry': entry.toJson(),
      if (memoryId != null) 'memory_id': memoryId,
    };
    final sent =
        await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingMemory.remove(requestId);
      return const PeerMemoryResult(ok: false, error: 'offline');
    }
    return completer.future.timeout(const Duration(seconds: 20), onTimeout: () {
      final pending = _pendingMemory.remove(requestId);
      if (pending != null && !pending.isCompleted) {
        pending.complete(const PeerMemoryResult(ok: false, error: 'timeout'));
      }
      return const PeerMemoryResult(ok: false, error: 'timeout');
    });
  }

  void _onMemoryResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final completer = _pendingMemory.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    final rawList = data['memories'];
    final memories = <AgentMemoryEntry>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map) {
          memories.add(
            AgentMemoryEntry.fromJson(Map<String, dynamic>.from(item)),
          );
        }
      }
    }
    completer.complete(PeerMemoryResult(
      ok: data['ok'] == true,
      editable: data['editable'] == true,
      memories: memories,
      memoryId: (data['memory_id'] as num?)?.toInt(),
      error: data['error'] as String?,
    ));
  }

  /// Query remote agent roster / status, or mutate hub-owned fields.
  ///
  /// Allowed ops from the app:
  /// - `list`
  /// - `engines` (engines the host knows, with whether each is installed)
  /// - `create` ([engine] + [cwd] + optional [name], [sessionMode], [additionalDirectories])
  /// - `remove` ([agentId])
  /// - `set_cwd` (primary workspace absolute path on the hub host)
  /// - `set_additional_directories` (full-replace absolute paths on the hub host)
  ///
  /// Start / stop / set_enabled stay hub-owned; this client refuses them.
  Future<PeerAgentManageResult> manageAgents({
    required String peerId,
    required String op,
    String? agentId,
    bool? enabled,
    String? cwd,
    List<String>? additionalDirectories,
    String? engine,
    String? name,
    String? sessionMode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    const allowed = {
      'list',
      'engines',
      'create',
      'remove',
      'set_cwd',
      'set_additional_directories',
    };
    if (!allowed.contains(op)) {
      _log.warning(
        'Rejected remote agent lifecycle op "$op"; hub owns start/stop/enable',
        tag: _tag,
      );
      return const PeerAgentManageResult(ok: false, error: 'unsupported');
    }
    final requestId = _uuid.v4();
    final completer = Completer<PeerAgentManageResult>();
    _pendingManage[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_manage_req',
      'request_id': requestId,
      'op': op,
      if (agentId != null) 'agent_id': agentId,
      if (enabled != null) 'enabled': enabled,
      if (cwd != null) 'cwd': cwd,
      if (additionalDirectories != null)
        'additional_directories': additionalDirectories,
      if (engine != null) 'engine': engine,
      if (name != null) 'name': name,
      if (sessionMode != null && sessionMode.isNotEmpty)
        'session_mode': sessionMode,
    };
    final sent =
        await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(ok: false, error: 'offline');
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    });
  }

  /// Register a new agent on the host. Refresh the agent list afterwards so
  /// the new agent shows up in this app.
  Future<PeerAgentManageResult> createAgent({
    required String peerId,
    required String engine,
    required String cwd,
    String? name,
    String? sessionMode,
    List<String>? additionalDirectories,
  }) {
    return manageAgents(
      peerId: peerId,
      op: 'create',
      engine: engine,
      cwd: cwd,
      name: name,
      sessionMode: sessionMode,
      additionalDirectories: additionalDirectories,
    );
  }

  Future<PeerAgentManageResult> removeAgent({
    required String peerId,
    required String remoteAgentId,
  }) {
    return manageAgents(
      peerId: peerId,
      op: 'remove',
      agentId: remoteAgentId,
    );
  }

  /// Set the hub instance's primary workspace root (absolute path).
  Future<PeerAgentManageResult> setCwd({
    required String peerId,
    required String remoteAgentId,
    required String cwd,
  }) {
    return manageAgents(
      peerId: peerId,
      op: 'set_cwd',
      agentId: remoteAgentId,
      cwd: cwd,
    );
  }

  /// Replace the hub instance's additional workspace roots (absolute paths).
  Future<PeerAgentManageResult> setAdditionalDirectories({
    required String peerId,
    required String remoteAgentId,
    required List<String> directories,
  }) {
    return manageAgents(
      peerId: peerId,
      op: 'set_additional_directories',
      agentId: remoteAgentId,
      additionalDirectories: directories,
    );
  }

  /// List directories on the Hub host (empty [path] → user home).
  Future<PeerFsBrowseResult> browseRemoteFs({
    required String peerId,
    String? path,
  }) async {
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      return const PeerFsBrowseResult(ok: false, error: 'offline');
    }
    final requestId = _uuid.v4();
    final completer = Completer<PeerFsBrowseResult>();
    _pendingFsBrowse[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'fs_browse_req',
      'request_id': requestId,
      if (path != null) 'path': path,
    };
    final sent =
        await PeerConnectionManager.instance.sendControl(peerId, payload);
    if (!sent) {
      _pendingFsBrowse.remove(requestId);
      return const PeerFsBrowseResult(ok: false, error: 'offline');
    }
    return completer.future.timeout(const Duration(seconds: 8), onTimeout: () {
      _pendingFsBrowse.remove(requestId);
      return const PeerFsBrowseResult(
        ok: false,
        error: 'timeout',
        unsupported: true,
      );
    });
  }

  void _onFsBrowseResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final completer = _pendingFsBrowse.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    if (data['ok'] != true) {
      completer.complete(PeerFsBrowseResult(
        ok: false,
        error: data['error'] as String? ?? 'browse failed',
      ));
      return;
    }
    final rawEntries = (data['entries'] as List?) ?? const [];
    final entries = <({String name, String path})>[];
    for (final item in rawEntries) {
      if (item is! Map) continue;
      final name = item['name'] as String?;
      final path = item['path'] as String?;
      if (name == null || path == null) continue;
      entries.add((name: name, path: path));
    }
    completer.complete(PeerFsBrowseResult(
      ok: true,
      path: data['path'] as String? ?? '',
      parent: data['parent'] as String?,
      entries: entries,
    ));
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
      agents
          .add(PeerAgentManageEntry.fromJson(Map<String, dynamic>.from(item)));
    }
    final engines = <PeerEngineEntry>[
      for (final item in (data['engines'] as List?) ?? const [])
        if (item is Map)
          PeerEngineEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
    final error = data['error'] as String?;
    bool? hubStoreOk;
    String? hubStoreDevice;
    final hubStore = data['hub_store'];
    if (hubStore is Map) {
      hubStoreOk = hubStore['ok'] == true;
      final device = hubStore['device'];
      if (device is String && device.trim().isNotEmpty) {
        hubStoreDevice = device.trim();
      }
    }
    completer.complete(PeerAgentManageResult(
      ok: data['ok'] == true,
      error: error,
      agents: agents,
      engines: engines,
      unsupported: error == 'unsupported',
      createdAgentId: data['agent_id'] as String?,
      hubStoreOk: hubStoreOk,
      hubStoreDevice: hubStoreDevice,
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
    final page = await _fetchHistory(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      sessionId: sessionId,
    );
    return page.messages;
  }

  /// [PeerHistoryPage.completed] 为 false 表示请求没发出或超时，和「远端确实没有正文」分开。
  Future<PeerHistoryPage> _fetchHistory({
    required String peerId,
    required String remoteAgentId,
    required String sessionId,
    String? cursor,
    int? limit,
  }) async {
    final key = '$remoteAgentId::$sessionId';
    if (_pendingHistory.containsKey(key)) {
      return _pendingHistory[key]!.future;
    }
    final completer = Completer<PeerHistoryPage>();
    _pendingHistory[key] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_session_history_req',
      'agent_id': remoteAgentId,
      'session_id': sessionId,
    };
    if (cursor != null && cursor.isNotEmpty) payload['cursor'] = cursor;
    if (limit != null) payload['limit'] = limit;
    final send =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    final sent = await send(peerId, payload);
    if (!sent) {
      _pendingHistory.remove(key);
      if (!completer.isCompleted) {
        completer.complete(PeerHistoryPage.incomplete);
      }
      return PeerHistoryPage.incomplete;
    }
    try {
      return await completer.future.timeout(const Duration(seconds: 45));
    } catch (_) {
      _pendingHistory.remove(key);
      if (!completer.isCompleted) {
        completer.complete(PeerHistoryPage.incomplete);
      }
      return PeerHistoryPage.incomplete;
    }
  }

  int _historyJsonInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
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
    final rawCursor = data['cursor'];
    final page = PeerHistoryPage(
      messages: messages,
      from: _historyJsonInt(data['from']),
      total: data.containsKey('total')
          ? _historyJsonInt(data['total'])
          : messages.length,
      cursor: rawCursor is String && rawCursor.isNotEmpty ? rawCursor : null,
      hasMore: data['has_more'] == true,
      reset: data['reset'] == true,
      completed: true,
      supportsCursor: data.containsKey('cursor'),
    );
    final completer = _pendingHistory.remove('$remoteId::$sessionId');
    if (completer != null && !completer.isCompleted) completer.complete(page);
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
    if (completer != null && !completer.isCompleted) {
      completer.complete(sessions);
    }
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
      final name = SessionUtils.cleanClaudeSessionTitle(s.title) ?? 'Session';
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
          // Title only. [updateChannel] also stamps updated_at = now, which
          // would make this historical session the one re-entry opens.
          await _db.updateChannelName(channelId, name);
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

  Future<String> _localChannelIdForRemoteSession(String sessionId) async {
    final psessId = syncedPeerChannelId(sessionId);
    return resolveLocalPeerChannelId(
      sessionId,
      psessExists: await _db.getChannelById(psessId) != null,
      legacyExists: await _db.getChannelById(sessionId) != null,
    );
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

  /// Remote session ids already mirrored while they had no `updatedAt`.
  Future<Set<String>> getSyncedUnstampedSessionIds(String localAgentId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(peerHistoryUnstampedPrefsKey(localAgentId));
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};
      return decoded.whereType<String>().where((id) => id.isNotEmpty).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> setSyncedUnstampedSessionIds(
    String localAgentId,
    Set<String> ids,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = ids.toList()..sort();
    await prefs.setString(
      peerHistoryUnstampedPrefsKey(localAgentId),
      jsonEncode(sorted),
    );
  }

  /// Incrementally sync all dirty remote sessions for a peer agent.
  ///
  /// 1. If the open channel has no local transcript yet, start its history
  ///    pull immediately so it does not wait on the full session list.
  /// 2. Enumerate remote sessions and ensure local channel shells exist.
  /// 3. Select dirty sessions via [selectDirtySessions] (watermark + overlap).
  /// 4. Pull history for each dirty session (prioritized channel first).
  /// 5. Advance the watermark to [syncStartedAt] only if every attempt finishes
  ///    without throwing.
  ///
  /// [onPrioritizedChannelDone] is invoked after the prioritized channel's
  /// first history page is written (even when 0 messages were written) so the
  /// UI can show it. Later pages keep downloading in the background.
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
    final openChannelId = prioritizeChannelId;
    var prioritizedDone = false;
    Future<int>? earlyHistory;
    String? earlyRemoteId;
    if (openChannelId != null &&
        openChannelId.isNotEmpty &&
        !hasInflightForChannel(openChannelId)) {
      final remoteId =
          remoteSessionIdFromChannelId(openChannelId) ?? openChannelId;
      final resolved = resolveLocalPeerChannelId(
        remoteId,
        psessExists:
            await _db.getChannelById(syncedPeerChannelId(remoteId)) != null,
        legacyExists: await _db.getChannelById(remoteId) != null,
      );
      final stored = await _db.getPeerHistoryCursor(openChannelId);
      final count = await _db.countChannelMessages(openChannelId);
      if (resolved == openChannelId &&
          peerHistoryShouldPrefetchOpenChannel(
            localMessageCount: count,
            hasCursorRow: stored != null,
          )) {
        earlyRemoteId = remoteId;
        earlyHistory = syncHistory(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          localAgentId: localAgentId,
          agentName: agentName,
          channelId: openChannelId,
          userId: userId,
          userName: userName,
          onFirstPageDone: (written) async {
            prioritizedDone = true;
            if (onPrioritizedChannelDone != null) {
              await onPrioritizedChannelDone(written);
            }
          },
        );
      }
    }
    final sessions = await fetchSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    if (sessions.isEmpty) {
      if (earlyHistory != null) {
        try {
          final written = await earlyHistory;
          return PeerAgentIncrementalSyncResult(
            currentChannelMessagesWritten: written < 0 ? 0 : written,
          );
        } catch (e, st) {
          _log.warning(
            'Open-channel history prefetch failed for $localAgentId: $e\n$st',
            tag: _tag,
            error: e,
          );
        }
      }
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
    final syncedUnstamped = await getSyncedUnstampedSessionIds(localAgentId);
    final remoteSessionIds = sessions.map((s) => s.sessionId).toSet();
    final prioritizeSessionId = peerRemoteSessionIdForLocalChannel(
      prioritizeChannelId,
      knownRemoteSessionIds: remoteSessionIds,
    );
    final cursorTotals = await _db.peerHistoryCursorTotalsByRemoteSession();
    final preliminary = selectDirtySessions(
      sessions,
      lastSyncAt: lastSyncAt,
      prioritizeSessionId: prioritizeSessionId,
      syncedUnstampedIds: syncedUnstamped,
    );
    final emptyLocal = <String>{};
    for (final session in sessions) {
      if (preliminary.any((item) => item.sessionId == session.sessionId)) {
        continue;
      }
      if (syncedUnstamped.contains(session.sessionId)) continue;
      final channelId =
          await _localChannelIdForRemoteSession(session.sessionId);
      if (await _db.countChannelMessages(channelId) == 0) {
        emptyLocal.add(session.sessionId);
      }
    }
    String? openEmptySessionId;
    if (openChannelId != null &&
        openChannelId.isNotEmpty &&
        await _db.countChannelMessages(openChannelId) == 0) {
      openEmptySessionId =
          remoteSessionIdFromChannelId(openChannelId) ?? openChannelId;
    }
    final dirty = assembleSessionsToSync(
      sessions: sessions,
      lastSyncAt: lastSyncAt,
      syncedUnstampedIds: syncedUnstamped,
      emptyLocalSessionIds: emptyLocal,
      cursorTotals: cursorTotals,
      prioritizeSessionId: prioritizeSessionId,
      openEmptySessionId: openEmptySessionId,
    );

    var historySessionsWritten = 0;
    var totalMessagesWritten = 0;
    var currentChannelMessagesWritten = 0;
    final mirroredUnstamped = <String>{};

    try {
      for (final session in dirty) {
        final psessId = syncedPeerChannelId(session.sessionId);
        final legacyId = session.sessionId;
        final channelId = resolveLocalPeerChannelId(
          session.sessionId,
          psessExists: await _db.getChannelById(psessId) != null,
          legacyExists: await _db.getChannelById(legacyId) != null,
        );
        if (earlyRemoteId != null &&
            session.sessionId == earlyRemoteId &&
            earlyHistory != null) {
          final written = await earlyHistory!;
          earlyHistory = null;
          if (written >= 0) {
            if (written > 0) {
              historySessionsWritten++;
              totalMessagesWritten += written;
            }
            if (written == 0 &&
                await _db.countChannelMessages(channelId) == 0) {
              mirroredUnstamped.add(session.sessionId);
            } else if (session.updatedAt == null &&
                (written > 0 ||
                    await _db.countChannelMessages(channelId) > 0)) {
              mirroredUnstamped.add(session.sessionId);
            }
            currentChannelMessagesWritten = written;
            prioritizedDone = true;
            continue;
          }
        }
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
        var notifiedFirstPage = false;
        final isPrioritized = prioritizeSessionId != null &&
            session.sessionId == prioritizeSessionId;
        final written = await syncHistory(
          peerId: peerId,
          remoteAgentId: remoteAgentId,
          localAgentId: localAgentId,
          agentName: agentName,
          channelId: channelId,
          userId: userId,
          userName: userName,
          sessionUpdatedAt: session.updatedAt,
          onFirstPageDone: isPrioritized
              ? (pageWritten) async {
                  notifiedFirstPage = true;
                  currentChannelMessagesWritten = pageWritten;
                  prioritizedDone = true;
                  if (onPrioritizedChannelDone != null) {
                    await onPrioritizedChannelDone(pageWritten);
                  }
                }
              : null,
        );
        final fetchFailed = written < 0;
        final stored = fetchFailed ? 0 : written;
        if (stored > 0) {
          historySessionsWritten++;
          totalMessagesWritten += stored;
        }
        if (!fetchFailed &&
            stored == 0 &&
            await _db.countChannelMessages(channelId) == 0) {
          mirroredUnstamped.add(session.sessionId);
        } else if (session.updatedAt == null &&
            (stored > 0 || await _db.countChannelMessages(channelId) > 0)) {
          mirroredUnstamped.add(session.sessionId);
        }
        if (isPrioritized) {
          currentChannelMessagesWritten = stored;
          if (!notifiedFirstPage) {
            prioritizedDone = true;
            if (onPrioritizedChannelDone != null) {
              await onPrioritizedChannelDone(stored);
            }
          }
        }
      }
    } catch (e, st) {
      _log.warning(
        'Incremental sync aborted for $localAgentId: $e\n$st',
        tag: _tag,
        error: e,
      );
      if (earlyHistory != null) {
        try {
          final written = await earlyHistory!;
          earlyHistory = null;
          if (written > 0) currentChannelMessagesWritten = written;
        } catch (_) {}
      }
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

    if (earlyHistory != null) {
      final written = await earlyHistory!;
      if (written > 0) {
        historySessionsWritten++;
        totalMessagesWritten += written;
        currentChannelMessagesWritten = written;
      }
    }

    // Prioritized session was not dirty — still notify so UI can clear spinner.
    if (!prioritizedDone &&
        prioritizeSessionId != null &&
        onPrioritizedChannelDone != null) {
      await onPrioritizedChannelDone(0);
    }

    final nextUnstamped = Set<String>.of(syncedUnstamped);
    for (final session in sessions) {
      if (session.updatedAt != null) nextUnstamped.remove(session.sessionId);
    }
    nextUnstamped.addAll(mirroredUnstamped);
    await setSyncedUnstampedSessionIds(localAgentId, nextUnstamped);
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
  /// A stored cursor pulls only the previous tail plus new messages. No cursor
  /// pages from the start. If local `peerhist_*` rows already exist, the last
  /// page drops mirrored rows the remote no longer has. An old Hub omits
  /// `cursor`; that response is applied with the full compare and no cursor is
  /// stored. Returns the number of messages written, 0 when nothing changed,
  /// or -1 when the request failed and should be retried.
  ///
  /// [onFirstPageDone] runs after the first page is applied, before later pages.
  Future<int> syncHistory({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String agentName,
    required String channelId,
    required String userId,
    required String userName,
    DateTime? sessionUpdatedAt,
    Future<void> Function(int written)? onFirstPageDone,
  }) async {
    final remoteSessionId =
        remoteSessionIdFromChannelId(channelId) ?? channelId;
    final stored = await _db.getPeerHistoryCursor(channelId);
    final hasMirrored = await _db.channelHasPeerhistMessages(channelId);
    var mode = peerHistoryFetchMode(storedCursor: stored?.cursor);
    var needsCleanup = mode == PeerHistoryFetchMode.rebuild && hasMirrored;
    final seenIds = <String>{};
    final request = peerHistoryHistoryRequest(
      mode: mode,
      cursor: stored?.cursor,
    );
    String? cursor = request.cursor;

    var written = 0;
    var pageIndex = 0;
    while (true) {
      final page = await _fetchHistory(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        sessionId: remoteSessionId,
        cursor: cursor,
        limit: kPeerHistoryPageLimit,
      );
      if (!page.completed) return -1;

      final step = peerHistoryStep(
        supportsCursor: page.supportsCursor,
        reset: page.reset,
        messagesEmpty: page.messages.isEmpty,
        hasMore: page.hasMore,
        pageCursor: page.cursor,
        needsCleanup: needsCleanup,
      );
      if (step.kind == PeerHistoryApplyKind.full) {
        final pageWritten = page.messages.isEmpty
            ? 0
            : await _mirrorFullHistory(
                history: page.messages,
                remoteSessionId: remoteSessionId,
                channelId: channelId,
                localAgentId: localAgentId,
                agentName: agentName,
                userId: userId,
                userName: userName,
                sessionUpdatedAt: sessionUpdatedAt,
              );
        written += pageWritten;
        if (pageIndex == 0 && onFirstPageDone != null) {
          await onFirstPageDone(pageWritten);
        }
        return written;
      }
      if (step.kind == PeerHistoryApplyKind.emptyReset) {
        await _storeHistoryCursor(
          channelId: channelId,
          remoteSessionId: remoteSessionId,
          cursor: '',
          total: 0,
        );
        if (pageIndex == 0 && onFirstPageDone != null) {
          await onFirstPageDone(0);
        }
        return written;
      }

      if (step.restartCleanup) {
        mode = PeerHistoryFetchMode.rebuild;
        needsCleanup = true;
        seenIds.clear();
        await _db.deletePeerHistoryCursor(channelId);
      }

      final pageIds = <String>[
        for (var i = 0; i < page.messages.length; i++)
          peerHistoryMessageId(page.messages[i], channelId, page.from + i),
      ];
      final pageWritten = page.messages.isEmpty
          ? 0
          : await _mirrorSliceHistory(
              history: page.messages,
              from: page.from,
              remoteSessionId: remoteSessionId,
              channelId: channelId,
              localAgentId: localAgentId,
              agentName: agentName,
              userId: userId,
              userName: userName,
              sessionUpdatedAt: sessionUpdatedAt,
              floorIds: needsCleanup ? seenIds : null,
            );
      written += pageWritten;
      if (mode == PeerHistoryFetchMode.rebuild) {
        seenIds.addAll(pageIds);
      }
      if (step.finishCleanup) {
        await _dropUnseenPeerhist(channelId, seenIds);
      }
      if (step.cursorAction == PeerHistoryCursorAction.store &&
          page.cursor != null) {
        final syncedThrough = page.from + page.messages.length;
        await _storeHistoryCursor(
          channelId: channelId,
          remoteSessionId: remoteSessionId,
          cursor: page.cursor!,
          total: page.hasMore ? syncedThrough : page.total,
        );
      }

      if (pageIndex == 0 && onFirstPageDone != null) {
        await onFirstPageDone(pageWritten);
      }
      pageIndex++;
      final nextCursor = page.cursor;
      if (!page.hasMore || nextCursor == null || nextCursor.isEmpty) {
        if (written > 0) {
          _log.info(
            'Synced $written history message(s) into $channelId',
            tag: _tag,
          );
        }
        return written;
      }
      cursor = nextCursor;
    }
  }

  Future<void> _storeHistoryCursor({
    required String channelId,
    required String remoteSessionId,
    required String cursor,
    required int total,
  }) {
    return _db.upsertPeerHistoryCursor(PeerHistoryCursorEntry(
      channelId: channelId,
      remoteSessionId: remoteSessionId,
      cursor: cursor,
      total: total,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  Future<void> _dropUnseenPeerhist(
    String channelId,
    Set<String> seenIds,
  ) async {
    final stamps = await _db.listPeerhistStamps(channelId);
    final doomed = peerHistoryRebuildDeletes(
      localPeerhistIds: [for (final stamp in stamps) stamp.id],
      seenIds: seenIds,
      preserveIds: _inflightPreserveIds(channelId),
    );
    await _db.deleteMessagesByIds(doomed.toList());
  }

  Future<int> _mirrorSliceHistory({
    required List<PeerHistoryMessage> history,
    required int from,
    required String remoteSessionId,
    required String channelId,
    required String localAgentId,
    required String agentName,
    required String userId,
    required String userName,
    DateTime? sessionUpdatedAt,
    Set<String>? floorIds,
  }) async {
    if (history.isEmpty) return 0;
    _completeInflightTurnsFromRemoteHistory(
      remoteSessionId: remoteSessionId,
      history: history,
    );

    final ids = <String>[
      for (var i = 0; i < history.length; i++)
        peerHistoryMessageId(history[i], channelId, from + i),
    ];
    final existingRows = await _db.getChannelMessagesByIds(channelId, ids);
    final existingRowsById = <String, Map<String, dynamic>>{
      for (final row in existingRows)
        if (row['id'] is String) row['id'] as String: row,
    };
    final existingById = <String, DateTime>{};
    for (final row in existingRows) {
      final id = row['id'] as String?;
      final at = DateTime.tryParse(row['created_at'] as String? ?? '');
      if (id != null && at != null) existingById[id] = at;
    }

    final sliceIds = ids.toSet();
    final peerhist = await _db.listPeerhistStamps(channelId);
    DateTime? latestMirroredLocalAt;
    for (final stamp in peerhist) {
      if (sliceIds.contains(stamp.id)) continue;
      if (floorIds != null && !floorIds.contains(stamp.id)) continue;
      final at = DateTime.tryParse(stamp.createdAt);
      if (at == null) continue;
      if (latestMirroredLocalAt == null || at.isAfter(latestMirroredLocalAt)) {
        latestMirroredLocalAt = at;
      }
    }
    final createdAts = assignPeerHistoryTimestamps(
      history,
      existingById: existingById,
      sessionUpdatedAt: sessionUpdatedAt,
      latestMirroredLocalAt: latestMirroredLocalAt,
      idFor: (m, i) => peerHistoryMessageId(m, channelId, from + i),
    );

    final preserveIds = _inflightPreserveIds(channelId);
    final missingPreserve = [
      for (final id in preserveIds)
        if (!existingRowsById.containsKey(id)) id,
    ];
    if (missingPreserve.isNotEmpty) {
      final extra =
          await _db.getChannelMessagesByIds(channelId, missingPreserve);
      for (final row in extra) {
        final id = row['id'] as String?;
        if (id != null) existingRowsById[id] = row;
      }
    }
    final preservedRoleContentKeys = <String>{};
    for (final id in preserveIds) {
      final row = existingRowsById[id];
      if (row == null) continue;
      final role = (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
      preservedRoleContentKeys.add(
        peerHistoryRoleContentKey(role, row['content'] as String? ?? ''),
      );
    }

    final indexes = peerHistorySliceWriteIndexes(
      history: history,
      from: from,
      channelId: channelId,
      existingById: existingRowsById,
      createdAts: createdAts,
    );
    final inserts = <StoredMessageInsert>[];
    for (final i in indexes) {
      final message = history[i];
      final msgId = ids[i];
      if (!existingRowsById.containsKey(msgId) &&
          preservedRoleContentKeys.contains(
            peerHistoryRoleContentKey(message.role, message.content),
          )) {
        continue;
      }
      inserts.add(_historyStoredRow(
        message: message,
        id: msgId,
        channelId: channelId,
        userId: userId,
        userName: userName,
        localAgentId: localAgentId,
        agentName: agentName,
        createdAt: createdAts[i],
        existingRow: existingRowsById[msgId],
      ));
    }
    await _db.createMessages(inserts);

    final localRows = await _db.listNonPeerhistMessages(channelId);
    final toDelete = localMessageIdsToDeleteOnPeerHistorySync(
      localRows: [
        for (final row in localRows)
          PeerHistorySyncLocalRow(
            id: row['id'] as String? ?? '',
            senderType: row['sender_type'] as String? ?? '',
            content: row['content'] as String? ?? '',
            metadataJson: row['metadata'] as String?,
            replyToId: row['reply_to_id'] as String?,
          ),
      ],
      remoteIds: peerHistorySliceDeleteRemoteIds(
        sliceIds: sliceIds,
        localPeerhistIds: [for (final stamp in peerhist) stamp.id],
      ),
      remoteRoleContentKeys: {
        for (final message in history)
          peerHistoryRoleContentKey(message.role, message.content),
      },
      preserveIds: preserveIds,
      remoteAgentContents: [
        for (final message in history)
          if (message.role != 'user') message.content,
      ],
      remoteTranscript: [
        for (final message in history)
          PeerHistoryRemoteEntry(role: message.role, content: message.content),
      ],
    );
    await _db.deleteMessagesByIds(toDelete.toList());
    if (AppLifecycleService().shouldSuppressNotification(channelId)) {
      await _db.markChannelMessagesAsRead(channelId);
    }
    return inserts.length;
  }

  Future<int> _mirrorFullHistory({
    required List<PeerHistoryMessage> history,
    required String remoteSessionId,
    required String channelId,
    required String localAgentId,
    required String agentName,
    required String userId,
    required String userName,
    DateTime? sessionUpdatedAt,
  }) async {
    if (history.isEmpty) return 0;

    // Group/workflow turns stream on the group channel but persist on this
    // session. If the remote already wrote the assistant reply, finish the
    // local wait — a missed agent_done must not block the whole stage.
    _completeInflightTurnsFromRemoteHistory(
      remoteSessionId: remoteSessionId,
      history: history,
    );

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

    final remoteIds = <String>{
      for (var i = 0; i < history.length; i++)
        peerHistoryMessageId(history[i], channelId, i),
    };
    // Lower bound for a synthesized batch, restricted to rows this transcript
    // owns. A live local row the remote does not have yet is genuinely newer
    // than the batch and must stay below it.
    DateTime? latestMirroredLocalAt;
    for (final entry in existingById.entries) {
      if (!remoteIds.contains(entry.key)) continue;
      final at = entry.value;
      if (latestMirroredLocalAt == null || at.isAfter(latestMirroredLocalAt)) {
        latestMirroredLocalAt = at;
      }
    }
    final createdAts = assignPeerHistoryTimestamps(
      history,
      existingById: existingById,
      sessionUpdatedAt: sessionUpdatedAt,
      latestMirroredLocalAt: latestMirroredLocalAt,
      idFor: (m, i) => peerHistoryMessageId(m, channelId, i),
    );

    // Skip the rewrite when text already matches. A later stamp on the same
    // text is repeated-sync drift (unstamped IDE turns re-anchored to now)
    // and must not move this session above a newer local conversation.
    if (!peerHistoryNeedsRewrite(
      history: history,
      existingAsc: existingAsc,
      createdAts: createdAts,
    )) {
      return 0;
    }

    // Live rows of a turn still in flight (the user's prompt, the streaming
    // partial). They stay put below, so the remote copy of the same text must
    // not be written as a second row.
    final preserveIds = <String>{};
    for (final rec in snapshotInflightTurns()) {
      if (rec.channelId != channelId) continue;
      if (rec.userMessageId.isNotEmpty) preserveIds.add(rec.userMessageId);
      if (rec.partialMessageId != null && rec.partialMessageId!.isNotEmpty) {
        preserveIds.add(rec.partialMessageId!);
      }
    }
    final preservedRoleContentKeys = <String>{};
    for (final id in preserveIds) {
      final row = existingRowsById[id];
      if (row == null) continue;
      final role = (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
      preservedRoleContentKeys.add(
        peerHistoryRoleContentKey(role, row['content'] as String? ?? ''),
      );
    }

    final remoteRoleContentKeys = <String>{};
    final remoteAgentContents = <String>[];
    final inserts = <StoredMessageInsert>[];
    for (var i = 0; i < history.length; i++) {
      final m = history[i];
      final isUser = m.role == 'user';
      final msgId = peerHistoryMessageId(m, channelId, i);
      remoteRoleContentKeys.add(peerHistoryRoleContentKey(m.role, m.content));
      if (!isUser) remoteAgentContents.add(m.content);
      // An in-flight local row already shows this text, and the UI is still
      // writing to it. Adding the `peerhist_*` twin now would double the bubble
      // and orphan the partial's reply link. The next sync — after the turn
      // settles and the row loses its reprieve — mirrors it and drops the local
      // copy, so the channel still converges on the remote transcript.
      if (!existingRowsById.containsKey(msgId) &&
          preservedRoleContentKeys
              .contains(peerHistoryRoleContentKey(m.role, m.content))) {
        continue;
      }
      // Fold the reconstructed progress section (thinking/tools/plan) into the
      // same metadata shape the live stream produces — the bubble renders it
      // as one collapsible block above the answer.
      final display = peerHistoryDisplayFields(
        m,
        baseMetadata: peerHistoryMessageMetadata(m),
      );
      final existingRow = existingRowsById[msgId];
      final isRead = preservedReadStateForHistorySync(
        remote: m,
        existingRow: existingRow,
      );
      inserts.add(
        StoredMessageInsert(
          id: msgId,
          channelId: channelId,
          senderId: isUser ? userId : localAgentId,
          senderType: isUser ? 'user' : 'agent',
          senderName: isUser ? userName : agentName,
          content: display.content,
          metadata: display.metadata,
          // ConflictAlgorithm.replace rewrites the whole row, so the reply link
          // has to be carried over explicitly — it is the only causal edge
          // MessageUtils.orderForDisplay can fall back on when stamps are coarse.
          replyToId: peerHistoryReplyToId(m.replyTo) ??
              existingRow?['reply_to_id'] as String?,
          createdAt: createdAts[i],
          isRead: isRead,
          conflictAlgorithm: ConflictAlgorithm.replace,
        ),
      );
    }
    await _db.createMessages(inserts);

    // Drop stale remote-mirrored rows, but keep the live rows collected above:
    // deleting a mid-turn bubble would make the previous assistant reply look
    // like the answer to the new message.
    final localRows = existingAsc.map((row) {
      return PeerHistorySyncLocalRow(
        id: row['id'] as String? ?? '',
        senderType: row['sender_type'] as String? ?? '',
        content: row['content'] as String? ?? '',
        metadataJson: row['metadata'] as String?,
        replyToId: row['reply_to_id'] as String?,
      );
    });
    final toDelete = localMessageIdsToDeleteOnPeerHistorySync(
      localRows: localRows,
      remoteIds: remoteIds,
      remoteRoleContentKeys: remoteRoleContentKeys,
      preserveIds: preserveIds,
      remoteAgentContents: remoteAgentContents,
      remoteTranscript: [
        for (final m in history)
          PeerHistoryRemoteEntry(role: m.role, content: m.content),
      ],
    );
    await _db.deleteMessagesByIds(toDelete.toList());

    // User is actively viewing this channel — synced rows must not resurrect
    // unread (covers the loadMessages ↔ syncHistory race on chat entry).
    if (AppLifecycleService().shouldSuppressNotification(channelId)) {
      await _db.markChannelMessagesAsRead(channelId);
    }
    return history.length;
  }

  Set<String> _inflightPreserveIds(String channelId) {
    final preserveIds = <String>{};
    for (final rec in snapshotInflightTurns()) {
      if (rec.channelId != channelId) continue;
      if (rec.userMessageId.isNotEmpty) preserveIds.add(rec.userMessageId);
      final partial = rec.partialMessageId;
      if (partial != null && partial.isNotEmpty) preserveIds.add(partial);
    }
    return preserveIds;
  }

  StoredMessageInsert _historyStoredRow({
    required PeerHistoryMessage message,
    required String id,
    required String channelId,
    required String userId,
    required String userName,
    required String localAgentId,
    required String agentName,
    required DateTime createdAt,
    required Map<String, dynamic>? existingRow,
  }) {
    final isUser = message.role == 'user';
    final display = peerHistoryDisplayFields(
      message,
      baseMetadata: peerHistoryMessageMetadata(message),
    );
    return StoredMessageInsert(
      id: id,
      channelId: channelId,
      senderId: isUser ? userId : localAgentId,
      senderType: isUser ? 'user' : 'agent',
      senderName: isUser ? userName : agentName,
      content: display.content,
      metadata: display.metadata,
      replyToId: peerHistoryReplyToId(message.replyTo) ??
          existingRow?['reply_to_id'] as String?,
      createdAt: createdAt,
      isRead: preservedReadStateForHistorySync(
        remote: message,
        existingRow: existingRow,
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  void _completeInflightTurnsFromRemoteHistory({
    required String remoteSessionId,
    required List<PeerHistoryMessage> history,
  }) {
    final lines = [
      for (final m in history)
        RemoteHistoryLine(role: m.role, content: m.content),
    ];
    for (final entry in _pending.entries.toList()) {
      final requestId = entry.key;
      final p = entry.value;
      if (p.completer.isCompleted) continue;
      final reply = settlingReplyFromRemoteTranscript(
        inflightSessionId: p.sessionId,
        syncedRemoteSessionId: remoteSessionId,
        history: lines,
        receivedContent: p.answerContent,
      );
      if (reply == null) continue;
      _log.info(
        'completing inflight turn $requestId from remote transcript '
        'session=$remoteSessionId (${reply.length} chars)',
        tag: _tag,
      );
      _finishPending(requestId, {'content': reply});
    }
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

  /// Ensure slash commands are cached for [localAgentId]. Skips the request
  /// only after a refresh on the current connection; a warmed disk cache is
  /// shown immediately but still refreshed once the peer is up.
  Future<void> ensureCommandsForLocalAgent(String localAgentId) async {
    if (_commandsFreshThisConnection.contains(localAgentId)) return;
    final agent = await _db.getRemoteAgentById(localAgentId);
    if (agent == null || !agent.isPeerAgent) return;
    final peerId = agent.sourcePeerId;
    final remoteId = agent.remoteAgentId;
    if (peerId == null || remoteId == null) return;
    if (_commandsFreshThisConnection.contains(remoteId)) return;
    final connected = debugConnectedPeerIdsOverride?.contains(peerId) ??
        PeerConnectionManager.instance.connectedPeerIds.contains(peerId);
    if (!connected) return;
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
    final sent = await _sendMetaControl(peerId, {
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
    _applyCommandsResp(
      remoteId,
      _parseCommandList(data['commands']),
      peerId: peerId,
      rev: _nonEmpty(data['rev']),
    );
  }

  void _applyCommandsResp(
    String remoteId,
    List<SlashCommandInfo> commands, {
    String? peerId,
    bool completePending = true,
    String? rev,
  }) {
    _commandsCache[remoteId] = commands;
    _commandsFreshThisConnection.add(remoteId);
    if (peerId != null && peerId.isNotEmpty) {
      _commandsFreshPeer[remoteId] = peerId;
    }
    _rememberCommands(remoteId, commands, rev: rev);
    // Mirror ACP's snapshot hook so the "/" resolver can read from either path.
    ACPAgentConnection.slashCommandsSnapshotHook?.call(remoteId, commands);
    final stream = _slashCommandsStreams[remoteId];
    if (stream != null && !stream.isClosed) {
      stream.add(List.unmodifiable(commands));
    }
    if (!completePending) return;
    final completer = _pendingCommands.remove(remoteId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(commands);
    }
  }

  /// Tool-call approval request forwarded by the hub. Surface it to the chat
  /// UI via the active request's `onActionConfirmation` callback (same card
  /// mechanism as the direct ACP flow). The user's tap later calls
  /// [submitApproval], which replies `agent_approval_resp` over the peer
  /// channel; the hub relays it as `agent.submitResponse` to its local agent.
  void _onApprovalReq(String peerId, Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) {
      _log.warning('agent_approval_req: missing request_id',
          tag: 'PeerApproval');
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
      pending.lastApprovalOpenedAt = DateTime.now();
      _approvalToRequest[approvalId] = requestId;
      if (!hasCallback) {
        _log.warning(
          'agent_approval_req: pending request has null onActionConfirmation '
          'for requestId=$requestId — will still forward if callback appears',
          tag: 'PeerApproval',
        );
      }
    }

    final rawActions =
        actions is List ? List<dynamic>.from(actions) : <dynamic>[];
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

  /// True when [approvalId] was already submitted (channel switch / timeout
  /// must not auto-deny a verdict the user already sent).
  bool hasSubmittedApproval(String approvalId) {
    if (approvalId.isEmpty) return false;
    return _submittedApprovals.containsKey(approvalId);
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
        sent = await PeerConnectionManager.instance
            .sendControl(peerId, payload)
            .timeout(const Duration(seconds: 8), onTimeout: () => false);
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
      p.upstreamReconnectingSince = null;
    }
    p.onChunk?.call(content);
    _schedulePersist(requestId);
  }

  void _onMetadata(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final raw = data['metadata'];
    final metadata =
        raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    if (metadata.isEmpty) return;
    final p = _pending[requestId];
    if (p == null) return;
    if (isHubKeepalive(metadata)) p.lastKeepaliveAt = DateTime.now();
    if (metadataResetsIdleClock(metadata)) {
      p.idleSince = DateTime.now();
      p.upstreamReconnectingSince = null;
    }
    p.onMetadata?.call(metadata);
  }

  /// Push metadata onto the in-flight turn for [channelId], if any.
  bool publishMetadataToChannel(
    String channelId,
    Map<String, dynamic> metadata,
  ) {
    if (channelId.isEmpty || metadata.isEmpty) return false;
    for (final p in _pending.values) {
      if (p.completer.isCompleted || p.channelId != channelId) continue;
      p.idleSince = DateTime.now();
      p.upstreamReconnectingSince = null;
      p.onMetadata?.call(metadata);
      return true;
    }
    return false;
  }

  Future<void> _onCliExecuteReq(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    Map<String, dynamic> result;
    try {
      result = await PeerCliExecuteHandler().handle(data);
    } catch (e) {
      result = {'ok': false, 'error': e.toString()};
    }
    final reqId = data['req_id'];
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': PeerCliExecuteHandler.respType,
      if (reqId != null) 'req_id': reqId,
      ...result,
    });
  }

  Future<void> _onSessionCreateReq(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    Map<String, dynamic> result;
    try {
      result = await SessionCreatePeerHandler(
        publishMetadata: publishMetadataToChannel,
      ).handle(data);
    } catch (e) {
      result = {'error': e.toString()};
    }
    final reqId = data['req_id'];
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': SessionCreatePeerHandler.respType,
      if (reqId != null) 'req_id': reqId,
      ...result,
    });
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
      _dropFreshCommands(event.peerId);
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
  ///    并启动应答看门狗：无应答时重发（重连竞态会偶发吞帧），重试耗尽仍无
  ///    应答（旧 hub 不支持续传）才明确失败。
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
      p.resumePurpose = _ResumePurpose.suspend;
      p.resumeBaseLength = p.receivedLength;
      _log.info(
        'resume turn requestId=$requestId known=${p.receivedLength}',
        tag: 'PeerApproval',
      );
      final sent = await _sendResumeReq(peerId, requestId, p);
      if (!sent) {
        // 仍未连通 —— 回滚标志，等下一次 connected 事件重试。
        p.resumeInFlight = false;
        p.resumePurpose = _ResumePurpose.none;
        p.resumeBaseLength = null;
        continue;
      }
      _watchResumeResponse(peerId, requestId, resumeRetryCount,
          failOnExhausted: true);
    }
  }

  /// 连接仍存活但长时间无输出 —— 向 Hub 拉取 replay buffer 中可能遗漏的
  /// chunk/done（Hub↔ACP 瞬断、隧道丢帧等）。失败只记日志，下轮看门狗重试。
  Future<void> _probeStalledTurn(
    String requestId,
    String peerId,
    _PendingRequest p,
  ) async {
    if (p.completer.isCompleted || p.resumeInFlight) return;
    p.lastStallProbeAt = DateTime.now();
    p.resumeInFlight = true;
    p.resumePurpose = _ResumePurpose.stallProbe;
    p.resumeBaseLength = p.receivedLength;
    _log.info(
      'stall probe requestId=$requestId known=${p.receivedLength}',
      tag: 'PeerApproval',
    );
    final sent = await _sendResumeReq(peerId, requestId, p);
    if (!sent) {
      p.resumeInFlight = false;
      p.resumePurpose = _ResumePurpose.none;
      p.resumeBaseLength = null;
      unawaited(_reconcileInflightFromRemoteHistory(p, requestId));
      return;
    }
    _watchResumeResponse(
      peerId,
      requestId,
      resumeRetryCount,
      failOnExhausted: false,
    );
    // 不依赖 resume 带回 done：远端 transcript 有助手回复即收口。
    unawaited(_reconcileInflightFromRemoteHistory(p, requestId));
  }

  Future<void> _reconcileInflightFromRemoteHistory(
    _PendingRequest p,
    String requestId,
  ) async {
    if (p.completer.isCompleted || p.sessionId.isEmpty) return;
    try {
      final history = await fetchHistory(
        peerId: p.peerId,
        remoteAgentId: p.remoteAgentId,
        sessionId: p.sessionId,
      );
      if (p.completer.isCompleted || history.isEmpty) return;
      _completeInflightTurnsFromRemoteHistory(
        remoteSessionId: p.sessionId,
        history: history,
      );
    } catch (e) {
      _log.warning(
        'stall-probe history reconcile failed requestId=$requestId: $e',
        tag: _tag,
        error: e,
      );
    }
  }

  /// 发一帧 resume_req（断点取 p.receivedLength 当前值）。
  Future<bool> _sendResumeReq(
    String peerId,
    String requestId,
    _PendingRequest p,
  ) {
    final sendControl =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    return sendControl(peerId, {
      'type': 'agent_turn_resume_req',
      'request_id': requestId,
      'known_content_length': p.receivedLength,
    });
  }

  /// 单次 resume 应答看门狗。应答到达（[_onTurnResumeResp] 复位
  /// resumeInFlight）或连接再次断开（[suspend] 复位 resumeInFlight）后自行
  /// 退役；无应答则重发 resume_req（帧可能被重连竞态吞掉，hub 端幂等），
  /// 重试耗尽仍无应答才按「对端不支持续传」判失败。
  void _watchResumeResponse(
    String peerId,
    String requestId,
    int retriesLeft, {
    required bool failOnExhausted,
  }) {
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted || !p.resumeInFlight) return;
    Timer(_effectiveResumeResponseTimeout, () async {
      final cur = _pending[requestId];
      if (cur == null || cur.completer.isCompleted) return;
      if (!cur.resumeInFlight) return;
      if (retriesLeft > 0) {
        _log.warning(
          'resume requestId=$requestId no answer in '
          '${_effectiveResumeResponseTimeout.inSeconds}s — resending '
          '(retries left: $retriesLeft, purpose=${cur.resumePurpose.name})',
          tag: 'PeerApproval',
        );
        // 刷新 drop-prefix 基准：重连后 live chunk 可能已补到，重发的
        // known_content_length 需反映最新 receivedLength。
        cur.resumeBaseLength = cur.receivedLength;
        final resent = await _sendResumeReq(peerId, requestId, cur);
        if (!resent) {
          // 连接又不可用 —— 回滚标志，等下一次 connected 事件重新走 resume。
          cur.resumeInFlight = false;
          cur.resumePurpose = _ResumePurpose.none;
          cur.resumeBaseLength = null;
          return;
        }
        _watchResumeResponse(
          peerId,
          requestId,
          retriesLeft - 1,
          failOnExhausted: failOnExhausted,
        );
        return;
      }
      if (!failOnExhausted && cur.resumePurpose == _ResumePurpose.stallProbe) {
        _log.warning(
          'stall probe requestId=$requestId timed out — will retry on next idle tick',
          tag: 'PeerApproval',
        );
        cur.resumeInFlight = false;
        cur.resumePurpose = _ResumePurpose.none;
        cur.resumeBaseLength = null;
        return;
      }
      // 重试耗尽（含旧 hub 完全不响应 resume_req）→ 明确失败。
      _pending.remove(requestId);
      _clearPersistedTurn(requestId);
      for (final e in _approvalToRequest.entries.toList()) {
        if (e.value == requestId) _approvalToRequest.remove(e.key);
      }
      _log.warning(
        'resume requestId=$requestId timed out after $resumeRetryCount '
        'retries — peer hub does not support turn resume or link lost it',
        tag: 'PeerApproval',
      );
      _markReconcileNeeded(requestId);
      cur.completer.completeError(
        Exception('对端不支持断点续传或任务已丢失，请重新发送'),
      );
    });
  }

  Duration get _effectiveResumeResponseTimeout =>
      debugResumeResponseTimeoutOverride ?? resumeResponseTimeout;

  /// Hub 侧 Hub↔ACP 传输断开：P2P 仍连着，冻结 idle 计时并等待恢复。
  void _onUpstreamReconnecting(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted) return;
    p.upstreamReconnectingSince ??= DateTime.now();
    _log.info(
      'upstream reconnecting requestId=$requestId — idle clock frozen',
      tag: 'PeerApproval',
    );
  }

  /// Hub 侧 Hub↔ACP 已恢复；若仍无 live 输出，stall probe 会在下一 tick 补拉。
  void _onUpstreamReconnected(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null || p.completer.isCompleted) return;
    p.upstreamReconnectingSince = null;
    p.idleSince = DateTime.now();
    _log.info(
      'upstream reconnected requestId=$requestId',
      tag: 'PeerApproval',
    );
  }

  /// 处理 agent_turn_resume_resp：先经 drop-prefix 去重（重连后 live chunk
  /// 可能先于 resp 到达，与 delta 前缀重叠），再按 status 走既有完成路径。
  void _onTurnResumeResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null) return;
    p.resumeInFlight = false;
    p.resumePurpose = _ResumePurpose.none;

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
    p.upstreamReconnectingSince = null;

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
        // Remote turn is finished. Bypass the openApprovals gate — a stale
        // count (hung submit / missed decrement) must not deadlock group
        // workflow on a member that already answered.
        _finishPending(requestId, {
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

  /// Re-fetch the peer's agent catalog and wait until it is written to SQLite.
  ///
  /// Used by agent detail "view workspace" so a stale in-memory [RemoteAgent]
  /// (opened from chat before the latest `agent_list_resp`) still picks up
  /// `workspace_uri`. Times out quietly if the peer never replies.
  Future<void> refreshAgentList(
    String peerId, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      return;
    }
    final completer = Completer<void>();
    _agentListWaiters.putIfAbsent(peerId, () => []).add(completer);
    _requestAgentList(peerId);
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _agentListWaiters[peerId]?.remove(completer);
    }
  }

  void _completeAgentListWaiters(String peerId) {
    final waiters = _agentListWaiters.remove(peerId);
    if (waiters == null) return;
    for (final c in waiters) {
      if (!c.isCompleted) c.complete();
    }
  }

  String? _workspaceUriFromAgentListEntry(Map raw) {
    final a = raw['workspace_uri'];
    final b = raw['workspaceUri'];
    final s = a is String ? a : (b is String ? b : null);
    if (s == null || !isPouchUri(s)) return null;
    return canonicalizeStoreWorkspaceUri(s) ?? s;
  }

  Future<void> _onAgentList(String peerId, Map<String, dynamic> data) async {
    final list = (data['agents'] as List?) ?? const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final seenRemoteIds = <String>{};
    final syncedLocalIds = <String>[];
    final peerName = await _peerDisplayName(peerId);
    final hostRoster = await _syncPouchRoster(peerId, list);

    try {
      for (final raw in list) {
        if (raw is! Map) continue;
        final remoteId = raw['id'] as String?;
        if (remoteId == null) continue;
        seenRemoteIds.add(remoteId);

        final localId = _localIdForPeerAgent(
          peerId: peerId,
          remoteId: remoteId,
          hostRoster: hostRoster,
        );
        final existing = await _db.getRemoteAgentById(localId);
        final capabilities =
            (raw['capabilities'] as List?)?.cast<String>() ?? const [];
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
        final workspaceUri = _workspaceUriFromAgentListEntry(raw);
        final workspaceUris = raw['workspace_uris'] is List
            ? raw['workspace_uris']
            : (raw['workspaceUris'] is List ? raw['workspaceUris'] : null);
        final cwd = raw['cwd'] as String?;
        final additionalDirectories = raw['additional_directories'] is List
            ? raw['additional_directories']
            : (raw['additionalDirectories'] is List
                ? raw['additionalDirectories']
                : null);

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
            if (hostRoster != null)
              'roster_hub_fingerprint': hostRoster.fingerprint,
            if (!PouchDutyState.isHost && remoteId == SheService.sheId)
              'is_she': true,
            // 宿主边界开关的最近一次广播，详情页据此默认只读/可编辑；
            // 打开编辑页时仍会用 agent_resume_get 权威刷新。
            if (raw['resume_editable'] is bool)
              'resume_editable': raw['resume_editable'],
            if (engine != null && engine.isNotEmpty) 'engine': engine,
            if (supportedModalities.isNotEmpty)
              'supported_modalities': supportedModalities,
            if (manageable) 'manageable': true,
            'enabled': enabled,
            'running': running,
            // 保留本地头像自定义标记，使其在每次同步后依然生效。
            if (existing?.metadata['avatar_overridden'] == true)
              'avatar_overridden': true,
            // 本机「是否在此 App 显示」由用户在设备详情里控制，同步时不得覆盖。
            if (existing?.metadata['hidden_on_this_app'] == true)
              'hidden_on_this_app': true,
            if (workspaceUri != null)
              'workspace_uri': workspaceUri
            else if (existing?.metadata['workspace_uri'] is String)
              'workspace_uri': existing!.metadata['workspace_uri'],
            if (workspaceUris is List)
              'workspace_uris': workspaceUris
            else if (manageable && workspaceUri != null)
              // Hub sent only primary — clear any stale multi-root list.
              'workspace_uris': [workspaceUri]
            else if (existing?.metadata['workspace_uris'] is List)
              'workspace_uris': existing!.metadata['workspace_uris'],
            if (cwd != null && cwd.isNotEmpty) 'cwd': cwd,
            if (additionalDirectories is List)
              'additional_directories': additionalDirectories
            else if (manageable)
              // Hub omitted the field → extras cleared.
              'additional_directories': const <String>[]
            else if (existing?.metadata['additional_directories'] is List)
              'additional_directories':
                  existing!.metadata['additional_directories'],
          },
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        );

        if (existing == null) {
          await _db.createRemoteAgent(agent);
        } else {
          await _db.updateRemoteAgent(agent);
        }
        syncedLocalIds.add(localId);
      }

      // 对端不再暴露的 agent → 删除。
      await _removeStalePeerAgents(peerId, keep: seenRemoteIds);

      SheAgentImpressionService.instance.scheduleRefreshAll(
        syncedLocalIds,
        announce: false,
      );

      _log.debug('Injected ${seenRemoteIds.length} peer agents from $peerId',
          tag: _tag);
      PeerConnectionManager.instance.notifyPeerListChanged();
      _completeAgentListWaiters(peerId);

      // Prefetch each agent's slash commands so the '/' palette works for
      // peer agents (which have no ACP connection to read them from).
      for (final remoteId in seenRemoteIds) {
        unawaited(fetchCommands(peerId: peerId, remoteAgentId: remoteId));
      }
    } catch (e) {
      _log.warning('Failed to inject peer agents: $e', tag: _tag);
      _completeAgentListWaiters(peerId);
    }
  }

  /// 主机先把名单写进名册，本机行再用卡的 id。客户端返回 null。
  Future<({String fingerprint, List<AgentRosterCard> cards})?> _syncPouchRoster(
    String peerId,
    List<Object?> agents,
  ) async {
    try {
      final peer = await _storage.getPeerById(peerId);
      final fingerprint = peer?.fingerprint.trim() ?? '';
      if (fingerprint.isEmpty) return null;
      final cards = await PouchRosterSync.applyIfHost(
        root: await StoreService.instance.storeRoot(),
        hubFingerprint: fingerprint,
        agents: agents,
      );
      if (cards == null) return null;
      return (fingerprint: fingerprint, cards: cards);
    } catch (e) {
      _log.warning('名册没有写上: $e', tag: _tag);
      return null;
    }
  }

  String _localIdForPeerAgent({
    required String peerId,
    required String remoteId,
    required ({String fingerprint, List<AgentRosterCard> cards})? hostRoster,
  }) {
    if (hostRoster != null) {
      final cardId = PouchRosterSync.cardIdFor(
        hostRoster.cards,
        hostRoster.fingerprint,
        remoteId,
      );
      if (cardId != null && cardId.isNotEmpty) return cardId;
    }
    return peerAgentLocalId(peerId, remoteId);
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
    // 内置引擎直接用打包的 SVG，不再把 Hub 下发的同一份字节另存一份。
    if (engineDefault != kGenericDefaultAvatar) return engineDefault;

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

  Future<void> _removeStalePeerAgents(String peerId,
      {required Set<String> keep}) async {
    final agents = await _db.getAllRemoteAgents();
    final retain = await _rosterCardIds();
    for (final a in agents) {
      if (a.protocol != ProtocolType.peer || a.sourcePeerId != peerId) continue;
      if (keep.contains(a.remoteAgentId)) continue;
      if (retain.contains(a.id)) {
        await _db.updateRemoteAgentStatus(a.id, 'offline');
        continue;
      }
      await _db.deleteRemoteAgent(a.id);
      unawaited(SheAgentImpressionService.instance.removeImpression(a.id));
    }
  }

  Future<Set<String>> _rosterCardIds() async {
    try {
      final root = await StoreService.instance.storeRoot();
      final role = await PouchRoleStore(root).load();
      if (!role.isHost) return const {};
      final cards = await AgentRosterStore(root).load();
      return {
        for (final card in cards)
          if (!card.boundToPouch) card.id,
      };
    } catch (_) {
      return const {};
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
      final pairedIds = (await PeerConnectionManager.instance.getAllPeers())
          .map((p) => p.id)
          .toSet();
      final agents = await _db.getAllRemoteAgents();
      final retain = await _rosterCardIds();
      var changed = false;
      for (final a in agents) {
        if (a.protocol != ProtocolType.peer) continue;
        if (a.sourcePeerId != null && pairedIds.contains(a.sourcePeerId)) {
          continue;
        }
        if (retain.contains(a.id)) {
          await _db.updateRemoteAgentStatus(a.id, 'offline');
          changed = true;
          continue;
        }
        await _db.deleteRemoteAgent(a.id);
        unawaited(SheAgentImpressionService.instance.removeImpression(a.id));
        changed = true;
      }
      if (changed) PeerConnectionManager.instance.notifyPeerListChanged();
    } catch (e) {
      _log.warning('reconcileDeletions failed: $e', tag: _tag);
    }
  }
}

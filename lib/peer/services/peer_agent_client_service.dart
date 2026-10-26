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
import '../../models/client_device_info.dart';
import '../../models/channel.dart';
import '../../models/agent_node.dart';
import '../../models/remote_agent.dart';
import '../../models/agent_memory_entry.dart';
import '../../models/acp_protocol.dart';
import '../../services/task/acp_task_contract.dart';
import '../../utils/progress_content_utils.dart';
import '../../services/chat_service.dart';
import '../../services/app_lifecycle_service.dart';
import '../../services/local_database_service.dart';
import '../../services/local_file_storage_service.dart';
import '../../services/logger_service.dart';
import '../../services/messaging/message_implicit_prompt.dart';
import '../../services/serial_task_queue.dart';
import '../../services/device_node/command_approval_inbox.dart';
import '../../services/device_node/device_command_runner.dart';
import '../../services/device_node/device_hello.dart';
import '../../services/approval/pending_approval_hub.dart';
import '../../services/approval/pending_approval_item.dart';
import '../../services/session/client_session_sync.dart';
import '../../services/session/cli_execute_peer_handler.dart';
import '../../services/session/session_create_peer_handler.dart';
import '../../services/she_agent_impression_service.dart';
import '../../services/she_service.dart';
import '../../services/local_user_identity.dart';
import '../../service_locator.dart' show getIt;
import '../interaction_card_close.dart';
import '../../utils/engine_avatars.dart';
import '../../utils/session_utils.dart';
import '../../services/messaging/chat_history_content.dart';
import '../../storage/agent_roster.dart';
import '../../storage/pouch_login.dart';
import '../../storage/pouch_login_keeper.dart';
import '../../storage/pouch_role.dart';
import '../../storage/store_service.dart';
import '../pouch_duties.dart';
import '../pouch_pair.dart';
import '../pouch_roster.dart';
import '../pouch_turn_relay.dart';
import 'peer_connection.dart' show PeerConnectionEvent, PeerConnectionEventType;
import '../peer_approval_payload.dart';
import '../host_she_turn.dart';
import 'peer_agent_ids.dart';
import 'peer_connection_manager.dart';
import 'peer_inflight_turn.dart';
import 'peer_storage_service.dart';
import 'peer_turn_resume.dart';
import '../../storage/agent_workspace_uris.dart';
import '../../storage/store_protocol.dart';

export 'peer_agent_ids.dart';
export 'peer_inflight_turn.dart' show PeerTurnInFlightException;
export 'peer_turn_resume.dart' show kFollowUpSettle, settledReplyLetsFollowUp;

/// 「已同步的远端 peer 会话」在本地 channel id 上的前缀。
///
/// 本地 channel id = `psess_<远端 sessionId>`。发消息时会剥离前缀，把裸的远端
/// sessionId 作为 `session_id` 发回对端，从而命中 acp-proxy 预置的映射并 resume
/// 到真实的上游会话——保证本地会话与远端一一对应、不串 session。
const String kSyncedPeerSessionPrefix = 'psess_';

/// Overlap subtracted from the last history-sync watermark so borderline
/// updates are not missed across consecutive syncs.
const Duration kPeerHistorySyncOverlap = Duration(minutes: 2);

/// Prefix of [peerHistoryLastSyncPrefsKey]. 按前缀作废时用它扫 key，
/// 不必先枚举本机有哪些 Agent。
const String peerHistoryLastSyncPrefsPrefix = 'peer_history_last_sync_';

/// Prefix of [peerHistoryUnstampedPrefsKey].
const String peerHistoryUnstampedPrefsPrefix = 'peer_history_unstamped_';

/// SharedPreferences key for the agent-level history sync watermark.
String peerHistoryLastSyncPrefsKey(String localAgentId) =>
    '$peerHistoryLastSyncPrefsPrefix$localAgentId';

/// SharedPreferences key for remote session ids already mirrored with no
/// `updatedAt`. See [selectDirtySessions].
String peerHistoryUnstampedPrefsKey(String localAgentId) =>
    '$peerHistoryUnstampedPrefsPrefix$localAgentId';

/// 由远端 sessionId 生成本地已同步会话的 channel id。
String syncedPeerChannelId(String remoteSessionId) =>
    '$kSyncedPeerSessionPrefix$remoteSessionId';

/// 若 [channelId] 是已同步的远端会话，返回其绑定的远端 sessionId，否则返回 null。
String? remoteSessionIdFromChannelId(String channelId) =>
    channelId.startsWith(kSyncedPeerSessionPrefix)
        ? channelId.substring(kSyncedPeerSessionPrefix.length)
        : null;

/// 空会话在主机上的登记结果。
enum HostEmptySessionResult { absent, removed, notEmpty, failed }

/// 用户删除会话时主机的处理结果。
///
/// [archived] 表示主机上已有消息，只做了归档；数据仍保留，同一会话再有新消息
/// 会重新出现在名单里。
enum HostSessionDeleteResult { absent, removed, archived, failed }

/// 发给主机的会话 id。`psess_` 壳剥掉，本机新建的 `dm_` 原样带上。
String hostSessionIdForChannel(String channelId) =>
    remoteSessionIdFromChannelId(channelId) ?? channelId;

/// 本机频道里，主机这次名单没有的那些。
///
/// 群绑定和 She 中转留下；刚在本机建、还没发出去的空会话留下。其余以主机
/// 名单为准删掉，两台客户端的会话列表才对得上。
///
/// [protectedChannelIds] 是当前绝不能删的会话（正在看、有回合在跑、刚登记
/// 到主机）：名单快照可能在操作之前就取好了，不能拿旧快照判它们「主机没有」。
/// [preserveClientSessions] 打开时跳过官方终端 / IDE 会话：主机关掉同步开关
/// 后名单里本来就不含它们，这不代表被删了。
Set<String> peerChannelIdsAbsentFromHost({
  required Iterable<Channel> local,
  required Set<String> hostSessionIds,
  Set<String> freshChannelIds = const {},
  Set<String> protectedChannelIds = const {},
  bool preserveClientSessions = false,
}) {
  final drop = <String>{};
  for (final channel in local) {
    if (channel.type != 'dm') continue;
    final group = channel.sourceGroupChannelId?.trim() ?? '';
    final she = channel.sourceSheChannelId?.trim() ?? '';
    if (group.isNotEmpty || she.isNotEmpty) continue;
    if (freshChannelIds.contains(channel.id)) continue;
    if (protectedChannelIds.contains(channel.id)) continue;
    if (preserveClientSessions && channel.sessionOrigin != null) continue;
    final bare = remoteSessionIdFromChannelId(channel.id);
    if (hostSessionIds.contains(channel.id)) continue;
    if (bare != null && hostSessionIds.contains(bare)) continue;
    drop.add(channel.id);
  }
  return drop;
}

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

/// 历史正文要拉哪些会话。关掉开关时，这个 agent 自己的官方终端 / IDE 会话不进这一轮。
List<PeerRemoteSession> sessionsMirroredForHistory(
  List<PeerRemoteSession> sessions, {
  required bool includeClientSessions,
}) {
  if (includeClientSessions) return sessions;
  return [
    for (final session in sessions)
      if (!session.isClientSession) session,
  ];
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

  /// 主机侧是否已将该会话标记为全部已读（或该会话为外部只读 IDE 会话）。
  final bool isRead;
  final bool readOnly;
  final int? readCount;
  final DateTime? readAt;

  /// 主机给的来源。`shepaw` 是权威会话；`ide` / `terminal` / `external` 是
  /// agent 自己的客户端会话。
  final String? source;

  PeerRemoteSession({
    required this.sessionId,
    this.title,
    this.updatedAt,
    this.messageCount,
    this.isRead = false,
    this.readOnly = false,
    this.readCount,
    this.readAt,
    this.source,
  });

  /// 这个 agent 自己的官方终端或 IDE 会话，不是 ShePaw 会话。
  bool get isClientSession => isAgentClientSessionSource(source);

  /// 要写进本地频道的来源标签。ShePaw 会话不打标签。
  String? get clientSessionOrigin => isClientSession ? source!.trim() : null;

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
    int? readCount;
    final rawReadCount = json['read_count'];
    if (rawReadCount is num) readCount = rawReadCount.toInt();
    DateTime? readAt;
    final rawReadAt = json['read_at'];
    if (rawReadAt is String && rawReadAt.isNotEmpty) {
      readAt = DateTime.tryParse(rawReadAt);
    } else if (rawReadAt is num) {
      final ms = rawReadAt.toInt();
      if (ms > 0) {
        readAt = DateTime.fromMillisecondsSinceEpoch(
          ms < 1000000000000 ? ms * 1000 : ms,
          isUtc: true,
        );
      }
    }
    final readOnly = json['read_only'] == true || json['archived'] == true;
    final isRead = json['is_read'] == true || json['is_read'] == 1 || readOnly;
    final rawSource = (json['source'] as String?)?.trim();
    return PeerRemoteSession(
      sessionId: id,
      title: (title != null && title.isNotEmpty) ? title : null,
      updatedAt: updated,
      messageCount: messageCount,
      isRead: isRead,
      readOnly: readOnly,
      readCount: readCount,
      readAt: readAt,
      source: (rawSource != null && rawSource.isNotEmpty) ? rawSource : null,
    );
  }
}

/// 解析 `agent_sessions_resp` / digest 里的会话数组。
///
/// 返回 `null` 表示这份名单不可信（缺字段、有条目解析不了）：调用方必须
/// 当成「没问到」，绝不能当成「主机确认没有会话」去剪枝。只有每个条目都
/// 读懂了才返回列表（可以是空列表）。
List<PeerRemoteSession>? parsePeerSessionList(Object? raw) {
  if (raw is! List) return null;
  final out = <PeerRemoteSession>[];
  for (final item in raw) {
    if (item is! Map) return null;
    final parsed = PeerRemoteSession.fromJson(Map<String, dynamic>.from(item));
    if (parsed == null) return null;
    out.add(parsed);
  }
  return out;
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
  final bool readOnly;
  final bool archived;
  final int? readCount;
  final DateTime? readAt;

  const PeerHistoryPage({
    this.messages = const [],
    this.from = 0,
    this.total = 0,
    this.cursor,
    this.hasMore = false,
    this.reset = false,
    this.completed = false,
    this.supportsCursor = false,
    this.readOnly = false,
    this.archived = false,
    this.readCount,
    this.readAt,
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

  /// Host-recorded read state for this message (`true` when already read on host).
  final bool? isRead;

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
    this.isRead,
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
    final rawIsRead = json['is_read'];
    final bool? isRead = (rawIsRead == true || rawIsRead == 1)
        ? true
        : (rawIsRead == false || rawIsRead == 0)
            ? false
            : null;
    return PeerHistoryMessage(
      role: role,
      // Older hub builds replayed the raw hint; ingest clean so it cannot
      // reach a bubble or the local database.
      content: MessageImplicitPrompt.stripImplicitBlocks(content),
      messageId: json['message_id'] as String?,
      createdAt: createdAt,
      progressContent: (rawProgress?.isNotEmpty ?? false) ? rawProgress : null,
      progressTitle: json['progress_title'] as String?,
      progressAutoCollapse: json['progress_auto_collapse'] as bool?,
      metadata: metadata,
      replyTo: json['reply_to'] as String?,
      isRead: isRead,
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

  /// 本地还有 mark_read 没补发出去时为 true，见下面已读那条的说明。
  bool keepLocalRead = false,
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
  if (_rowClientDeviceKey(existingRow) != _messageClientDeviceKey(message)) {
    return true;
  }
  if (message.isRead == true && (existingRow['is_read'] as int? ?? 0) == 0) {
    return true;
  }
  // 主机权威：主机说没读，本地已读也要跟过去（已读口径已定为主机权威）。
  // 例外是本地还有 mark_read 没补发出去 —— 那时远端未读只是上行迟到，不是
  // 主机否定了已读，跟过去会让红点莫名复活，补发成功后再说。
  if (message.isRead != true &&
      (existingRow['is_read'] as int? ?? 0) == 1 &&
      !keepLocalRead) {
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
  bool keepLocalRead = false,
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
      keepLocalRead: keepLocalRead,
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
  bool keepLocalRead = false,
}) {
  final indexes = <int>[];
  for (var i = 0; i < history.length && i < createdAts.length; i++) {
    final id = peerHistoryMessageId(history[i], channelId, from + i);
    if (peerHistoryRowNeedsWrite(
      message: history[i],
      existingRow: existingById[id],
      createdAt: createdAts[i],
      keepLocalRead: keepLocalRead,
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

/// 主机回放的引用是裸 id，本机存哪一形态要看这条通道自己用哪一形态：agent
/// 会话（`psess_*`）的行是 `peerhist_*`，惜宝单聊与群聊的行是裸 id。一律套前缀
/// 会让惜宝那边的引用指向一条本机根本不存在的行。
///
/// [hostWrapsIds] 直接取这条 `message.created` 自己的 id 形态 —— 同一个通道里
/// 两者必然一致，不用再查一次库。
String? replyToIdInLocalForm(String? replyTo, {required bool hostWrapsIds}) {
  final raw = replyTo?.trim() ?? '';
  if (raw.isEmpty) return null;
  return hostWrapsIds ? peerHistoryReplyToId(raw) : bareMessageId(raw);
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

String _rowClientDeviceKey(Map<String, dynamic> row) {
  final raw = row['metadata'];
  Map? decoded;
  if (raw is Map) {
    decoded = raw;
  } else if (raw is String && raw.isNotEmpty) {
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map) decoded = parsed;
    } catch (_) {}
  }
  if (decoded == null) return '';
  final name =
      (decoded[ClientDeviceInfo.deviceNameMetaKey] as String?)?.trim() ?? '';
  final form =
      (decoded[ClientDeviceInfo.deviceFormMetaKey] as String?)?.trim() ?? '';
  return '$form|$name';
}

String _messageClientDeviceKey(PeerHistoryMessage m) {
  final meta = m.metadata;
  if (meta == null) return '';
  final name =
      (meta[ClientDeviceInfo.deviceNameMetaKey] as String?)?.trim() ?? '';
  final form =
      (meta[ClientDeviceInfo.deviceFormMetaKey] as String?)?.trim() ?? '';
  return '$form|$name';
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
    for (final key in const [
      ClientDeviceInfo.deviceIdMetaKey,
      ClientDeviceInfo.deviceNameMetaKey,
      ClientDeviceInfo.deviceFormMetaKey,
    ]) {
      final val = protocol[key];
      if (val is String && val.trim().isNotEmpty) {
        meta[key] = val.trim();
      }
    }
  }
  final progress = m.progressContent;
  if (progress != null && progress.isNotEmpty) {
    meta['progress_content'] = capProgressContent(progress);
    meta['collapsible'] = true;
    meta['collapsible_title'] = m.progressTitle ?? 'Details';
    meta['auto_collapse'] = m.progressAutoCollapse ?? true;
  }
  return meta.isEmpty ? null : meta;
}

/// 回放或更新没有进度时，留下本机已经记下的折叠区。
///
/// 有新的非空进度则以新的为准。传入的 metadata 没有进度、库里有，就把库里的
/// `progress_content`（以及折叠标题）抄回来，避免后一次写入把工具步骤盖掉。
Map<String, dynamic>? metadataPreservingProgress({
  required Map<String, dynamic>? incoming,
  required String? existingMetadataJson,
}) {
  Map<String, dynamic>? existing;
  final raw = existingMetadataJson;
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) existing = Map<String, dynamic>.from(decoded);
    } catch (_) {}
  }
  final existingProgress = existing?['progress_content'];
  final hasExisting =
      existingProgress is String && existingProgress.trim().isNotEmpty;
  if (!hasExisting) return incoming;
  final incomingProgress = incoming?['progress_content'];
  if (incomingProgress is String && incomingProgress.trim().isNotEmpty) {
    return incoming;
  }
  final merged = Map<String, dynamic>.from(incoming ?? {});
  // 老数据可能存了几百 KB，重写时顺手裁掉。
  merged['progress_content'] = capProgressContent(existingProgress);
  for (final key in const [
    'collapsible',
    'collapsible_title',
    'auto_collapse',
  ]) {
    if (!merged.containsKey(key) && existing!.containsKey(key)) {
      merged[key] = existing[key];
    }
  }
  return merged;
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
/// turn content is unchanged, or honor `remote.isRead == true` recorded on the
/// host. [ConflictAlgorithm.replace] would otherwise reset `is_read` to 0 and
/// resurrect unread badges for locally-created or cross-device read sessions.
int preservedReadStateForHistorySync({
  required PeerHistoryMessage remote,
  Map<String, dynamic>? existingRow,
}) {
  if (remote.isRead == true) return 1;
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
  final String baseUrl;

  /// 主机是否已保存密钥。旧 Hub 不带这个字段时为 null，明文永远不在这里。
  final bool? hasApiKey;
  final List<PeerModelOption> options;

  PeerAgentModel({
    required this.value,
    required this.displayName,
    this.description = '',
    this.baseUrl = '',
    this.hasApiKey,
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
      baseUrl: (json['base_url'] as String?) ?? '',
      hasApiKey:
          json.containsKey('has_api_key') ? json['has_api_key'] == true : null,
      options: options,
    );
  }

  Map<String, dynamic> toJson() => {
        'value': value,
        'display_name': displayName,
        'description': description,
        if (baseUrl.isNotEmpty) 'base_url': baseUrl,
        if (hasApiKey != null) 'has_api_key': hasApiKey,
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

/// 某个实例上的一段会话。运行中、空闲、排队可以同时存在。
class PeerEngineSession {
  final String sessionKey;

  /// 有回合正在引擎里跑。
  final bool running;

  /// 子进程还留着，下一轮可以直接复用。
  final bool idle;

  /// 这段会话排了多少条还没开始的消息。
  final int queued;

  const PeerEngineSession({
    required this.sessionKey,
    this.running = false,
    this.idle = false,
    this.queued = 0,
  });

  factory PeerEngineSession.fromJson(Map<String, dynamic> json) {
    return PeerEngineSession(
      sessionKey: (json['session_key'] as String?)?.trim() ?? '',
      running: json['running'] == true,
      idle: json['idle'] == true,
      queued: (json['queued'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 一个 Agent 实例的运行时占用，来自 `engine_status_resp.engines[].instances`。
class PeerEngineInstance {
  final String id;
  final String name;
  final String cwd;
  final bool enabled;
  final int connections;
  final int activeConversations;
  final int queued;
  final int queuedSessions;
  final List<PeerEngineSession> sessions;

  const PeerEngineInstance({
    required this.id,
    required this.name,
    this.cwd = '',
    this.enabled = true,
    this.connections = 0,
    this.activeConversations = 0,
    this.queued = 0,
    this.queuedSessions = 0,
    this.sessions = const [],
  });

  factory PeerEngineInstance.fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim() ?? '';
    final name = (json['name'] as String?)?.trim() ?? '';
    return PeerEngineInstance(
      id: id,
      name: name.isEmpty ? id : name,
      cwd: (json['cwd'] as String?)?.trim() ?? '',
      enabled: json['enabled'] != false,
      connections: (json['connections'] as num?)?.toInt() ?? 0,
      activeConversations:
          (json['active_conversations'] as num?)?.toInt() ?? 0,
      queued: (json['queued'] as num?)?.toInt() ?? 0,
      queuedSessions: (json['queued_sessions'] as num?)?.toInt() ?? 0,
      sessions: [
        for (final item in (json['sessions'] as List?) ?? const [])
          if (item is Map)
            PeerEngineSession.fromJson(Map<String, dynamic>.from(item)),
      ].where((session) => session.sessionKey.isNotEmpty).toList(),
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

  /// 这台主机上登记了多少个使用该引擎的实例。
  final int instanceCount;

  /// 活跃的引擎子进程连接数。
  final int connections;

  /// 正在引擎里跑的对话数。
  final int activeConversations;

  /// 这个引擎所有实例上排队等待的消息条数。
  final int queued;

  /// 有排队的会话数。
  final int queuedSessions;

  /// 使用该引擎的实例，带每段会话的运行与排队情况。
  final List<PeerEngineInstance> instances;

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
    this.instanceCount = 0,
    this.connections = 0,
    this.activeConversations = 0,
    this.queued = 0,
    this.queuedSessions = 0,
    this.instances = const [],
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
      instanceCount: (json['instance_count'] as num?)?.toInt() ?? 0,
      connections: (json['connections'] as num?)?.toInt() ?? 0,
      activeConversations:
          (json['active_conversations'] as num?)?.toInt() ?? 0,
      queued: (json['queued'] as num?)?.toInt() ?? 0,
      queuedSessions: (json['queued_sessions'] as num?)?.toInt() ?? 0,
      instances: [
        for (final item in (json['instances'] as List?) ?? const [])
          if (item is Map)
            PeerEngineInstance.fromJson(Map<String, dynamic>.from(item)),
      ].where((instance) => instance.id.isNotEmpty).toList(),
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

  /// 机器可读的错误码，比如工作节点离线时的 `node_offline`。
  final String? code;

  const PeerAgentManageResult({
    required this.ok,
    this.error,
    this.agents = const [],
    this.engines = const [],
    this.unsupported = false,
    this.createdAgentId,
    this.hubStoreOk,
    this.hubStoreDevice,
    this.code,
  });

  bool get nodeOffline => code == 'node_offline';
}

/// Hub host directory listing from `fs_browse_resp`.
class PeerFsBrowseResult {
  final bool ok;
  final String? error;
  final String path;
  final String? parent;
  final List<({String name, String path})> entries;
  final bool unsupported;
  final String? code;

  const PeerFsBrowseResult({
    required this.ok,
    this.error,
    this.path = '',
    this.parent,
    this.entries = const [],
    this.unsupported = false,
    this.code,
  });

  bool get nodeOffline => code == 'node_offline';
}

/// `engine_status_resp.summary` 的汇总额。旧主机不带这个字段时由引擎列表兜底。
class PeerEngineStatusSummary {
  final int engines;
  final int availableEngines;
  final int instances;
  final int enabledInstances;
  final int connections;
  final int activeConversations;
  final int queued;
  final int queuedSessions;

  const PeerEngineStatusSummary({
    this.engines = 0,
    this.availableEngines = 0,
    this.instances = 0,
    this.enabledInstances = 0,
    this.connections = 0,
    this.activeConversations = 0,
    this.queued = 0,
    this.queuedSessions = 0,
  });

  factory PeerEngineStatusSummary.fromJson(
    Map<String, dynamic> data,
    List<PeerEngineEntry> engines,
  ) {
    final raw = data['summary'];
    final map = raw is Map ? Map<String, dynamic>.from(raw) : const <String, dynamic>{};
    int fallback(String key, int value) => (map[key] as num?)?.toInt() ?? value;
    final instanceCount =
        engines.fold<int>(0, (total, engine) => total + engine.instanceCount);
    return PeerEngineStatusSummary(
      engines: fallback('engines', engines.length),
      availableEngines: fallback(
        'available_engines',
        engines.where((engine) => engine.available).length,
      ),
      instances: fallback('instances', instanceCount),
      enabledInstances: fallback('enabled_instances', instanceCount),
      connections: fallback(
        'connections',
        engines.fold<int>(0, (total, engine) => total + engine.connections),
      ),
      activeConversations: fallback(
        'active_conversations',
        engines.fold<int>(
          0,
          (total, engine) => total + engine.activeConversations,
        ),
      ),
      queued: fallback(
        'queued',
        engines.fold<int>(0, (total, engine) => total + engine.queued),
      ),
      queuedSessions: fallback(
        'queued_sessions',
        engines.fold<int>(0, (total, engine) => total + engine.queuedSessions),
      ),
    );
  }
}

/// `engine_status_resp` 的解析结果。
class PeerEngineStatusResult {
  final bool ok;
  final String? error;
  final bool unsupported;
  final String? code;
  final List<PeerEngineEntry> engines;
  final PeerEngineStatusSummary summary;

  /// 主机扫描 PATH 的时间（毫秒），0 表示没有。
  final int scannedAt;

  const PeerEngineStatusResult({
    required this.ok,
    this.error,
    this.unsupported = false,
    this.code,
    this.engines = const [],
    this.summary = const PeerEngineStatusSummary(),
    this.scannedAt = 0,
  });

  bool get nodeOffline => code == 'node_offline';
}

/// `engine_control_resp` 的解析结果。
class PeerEngineControlResult {
  final bool ok;
  final String? error;
  final String? code;
  final bool unsupported;

  /// 杀掉的引擎子进程数。
  final int killed;

  /// 一并清掉的排队消息条数。
  final int dropped;

  const PeerEngineControlResult({
    required this.ok,
    this.error,
    this.code,
    this.unsupported = false,
    this.killed = 0,
    this.dropped = 0,
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
enum _ResumePurpose { none, suspend, stallProbe, deliveryProbe }

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
  void Function(Map<String, dynamic>)? onForm;
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

  /// 重连续传成功后的短周期补拉定时器：主机不会往重连后的新连接续推，
  /// 靠它把后续分片和终态拉回来。
  Timer? catchUpTimer;

  /// 最近一张审批卡到达的时刻。闸门过期后允许 stall probe。
  DateTime? lastApprovalOpenedAt;

  /// Hub 通知上游 ACP 正在重连 —— idle 计时冻结，避免 P2P 仍连着但
  /// Hub↔Agent 恢复期间误触 30min 超时。
  DateTime? upstreamReconnectingSince;

  /// 最近一次 Hub keepalive（上游仍在 working）。只推迟 idle 超时判失败，
  /// 不参与 settle / stall probe。
  DateTime? lastKeepaliveAt;

  /// 这条已经交给主机排队，还没轮到它。空闲超时不能把它判死。
  bool heldOnHost = false;

  /// 主机收下排队（true）或已经直接开跑（false）。
  Completer<bool>? queueAck;

  /// 排队消息的用户正文。回合真正结束时补进本地聊天记录。
  String? parkedText;

  /// 发出 resume_req 时的 receivedLength 基准，用于 delta 去重（drop-prefix）。
  int? resumeBaseLength;

  /// 是否已收到主机针对该 turn 的任何业务帧（chunk / metadata / queued /
  /// 审批卡 / done / error …）。`agent_chat` 可能被半开连接静默吞掉；
  /// 发出后一段时间仍为 false 时要主动向主机确认。
  bool heardFromHost = false;

  /// 发出 `agent_chat` 后等待首个主机帧的确认定时器。
  Timer? deliveryProbeTimer;

  /// 首次发出 `agent_chat` 的原始帧。投递确认失败时原样补发（同一个
  /// request_id，主机侧 `accept_once` 保证不会执行两遍）。
  Map<String, dynamic>? agentChatFrame;

  /// 已经自动补发过几次。只补一次，避免在坏链路上无限重发。
  int agentChatResendCount = 0;

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
    this.onForm,
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
  PeerAgentClientService._() {
    // 登录回包比通道更早到。这时候拉名单，帧还没密封，主机会丢掉，
    // 会话列表和惜宝的模型就一直是空的。等通道真正装上再拉。
    PouchChannel.installed.listen((session) {
      if (!_running && !debugTreatAsRunning) return;
      _greetHostIfConnected(session.hostPeerId);
    });
  }

  static final PeerAgentClientService instance = PeerAgentClientService._();

  final CommandApprovalInbox commandApprovals = CommandApprovalInbox();

  static const _tag = 'PeerAgentClient';

  /// Upper bound for a single peer agent chat request when the agent produces
  /// no output. A peer that stays connected but never answers must not hang a
  /// group orchestration forever. Each streaming chunk/metadata resets the
  /// idle clock; approval waits are uncapped — see [_awaitTurnCompletion].
  static const Duration chatTimeout = Duration(minutes: 30);

  /// 连接仍存活但距上次 agent 输出超过该时长 → 向 Hub 发
  /// `agent_turn_resume_req` 补拉（对齐直连 ACP 的 180s stall watchdog）。
  static const Duration stallProbeInterval = Duration(seconds: 180);

  /// 重连续传成功后的补拉周期。
  ///
  /// 主机那条回合的转发通道还挂在断开前的连接上，重连不会自动续推；
  /// 只靠 180s 停滞探测的话，用户要等到下一轮探测才看见后续正文和终态。
  /// 这里按短周期主动 resume，直到 done / error 或再次断线。
  static const Duration reconnectCatchUpInterval = Duration(seconds: 3);

  /// 断连挂起（等待重连续传）的最长时长。挂起期间 idle 计时冻结（对端本来
  /// 就不可能有帧到达），超过该时长说明重连无望，判 turn 失败。
  /// 比 hub 的审批期限（`SHEPAW_ACP_APPROVAL_SECS`，默认 30 分钟）宽得多：
  /// 手机回来得晚也不要紧，turn 还在跑就不该先放弃、丢掉本可续传的回复。
  static const Duration suspendWaitHardCap = Duration(hours: 25);

  /// resume_req 发出后对端无应答的容忍时长（旧版本 hub 不支持续传时
  /// 不会回复），超时按「对端不支持续传」失败，避免无限悬挂。
  static const Duration resumeResponseTimeout = Duration(seconds: 10);

  /// 用户发消息时连接不可用（典型：刚切网）主动重连并等待的上限。
  /// connectivity 监听侧有 800ms 去抖 + 最多 3s 探活，再留出握手时间。
  static const Duration _controlReconnectWait = Duration(seconds: 6);

  /// `agent_chat` 发出后，若这段时间内没有收到主机任何帧，就主动发一次
  /// `agent_turn_resume_req` 确认投递。
  ///
  /// 主机收到 `agent_chat` 时同步 claim turn；对刚发出的 turn，resume 返回
  /// `lost` 基本等价于「这一帧没到主机」。比等 120s 连接活性超时后才报
  /// 「任务已丢失」快得多，也能把消息及时交回输入框重试。
  static const Duration deliveryProbeDelay = Duration(milliseconds: 2500);

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
  ///
  /// `null` 表示这次没问到（解析失败 / 帧不完整 / 超时），和「主机确认没有
  /// 会话」的空列表必须分开，否则一次坏帧就会把本地会话删光。
  final Map<String, Completer<List<PeerRemoteSession>?>> _pendingSessions = {};

  /// Outstanding agent_client_sessions_sync_set_req per request id.
  final Map<String, Completer<bool>> _pendingClientSyncSet = {};

  /// 空会话登记 / 删除，按 request id 等回包。
  final Map<String, Completer<Map<String, dynamic>>> _pendingHostSessionOpen =
      {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingHostSessionDrop =
      {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingHostSessionDelete =
      {};

  /// 正在登记的空会话。离开这条会话时要等它结束，避免主机上留下没人删的空记录。
  final Map<String, Future<bool>> _hostEmptyOpens = {};

  /// 刚成功登记到主机的会话（channelId → 登记时刻）。
  ///
  /// 登记成功会清掉 fresh 标记，但别的会话名单快照可能是在登记之前取的；
  /// 用旧快照剪枝会把它当「主机没有」删掉。短时间保护一下。
  final Map<String, DateTime> _recentlyOpenedHostSessions = {};
  static const _recentOpenProtection = Duration(minutes: 2);

  Set<String> _recentlyOpenedChannelIds() {
    final now = DateTime.now();
    _recentlyOpenedHostSessions.removeWhere(
      (_, at) => now.difference(at) >= _recentOpenProtection,
    );
    return _recentlyOpenedHostSessions.keys.toSet();
  }

  /// 主机在 agent_sessions_resp 里带回的它自己的时刻（peer id → epoch ms）。
  ///
  /// 历史同步的水位要记在主机的时间轴上：会话要不要重拉是拿主机的
  /// `updatedAt` 比出来的，若水位记的是本机时钟，手机快于主机超过 overlap
  /// 就会把会话判成不脏而整段跳过。
  final Map<String, int> _hostNowMs = {};

  /// Outstanding agent_sessions_digest_req per peer id.
  final Map<String, Completer<Map<String, List<PeerRemoteSession>>?>>
      _pendingSessionsDigest = {};

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

  /// Outstanding she_model_set_req keyed by request_id.
  final Map<String, Completer<bool>> _pendingSheModel = {};

  /// Outstanding she_catalog_put_req keyed by request_id.
  final Map<String, Completer<bool>> _pendingSheCatalog = {};

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

  /// Outstanding engine_status_req keyed by request_id.
  final Map<String, Completer<PeerEngineStatusResult>> _pendingEngineStatus =
      {};

  /// Outstanding engine_control_req keyed by request_id.
  final Map<String, Completer<PeerEngineControlResult>> _pendingEngineControl =
      {};

  /// 刚在主机或工作节点创建出的远端实例（`$peerId::$remoteId` → 创建时间）。
  ///
  /// 工作节点创建实例时，`agent_manage_resp` 经主机流通道先回到本机，而工作节点
  /// 随后发出的 `worker.agents` 名册帧还在主机队列里处理；中间若夹着一轮旧的
  /// `agent_list_resp`，[_removeStalePeerAgents] 不能把刚先行落库的新实例当成
  /// 「已被删除」清掉。
  final Map<String, DateTime> _recentlyCreatedAgents = {};
  static const Duration _recentlyCreatedAgentTtl = Duration(seconds: 15);

  /// Maps hub approval_id → agent_chat request_id for deferred completion.
  final Map<String, String> _approvalToRequest = {};

  /// Approvals that arrived after agent_done already cleared `_pending`.
  /// Kept briefly so a late UI path can still surface / submit them.
  final Map<String, Map<String, dynamic>> _orphanedApprovals = {};

  /// 挂不上活动 turn 的 AskUserQuestion 表单（approvalId → 原始帧）。
  /// 和 [_orphanedApprovals] 同一个成因：hub 现在会在手机重连后补发卡片，
  /// 但那时的 `_pending` 可能已被 resume 重试耗尽清掉、或 turn 刚从磁盘
  /// 恢复还没重新挂上 onForm —— 两种情况都没有回调可投递。丢掉就等于主机
  /// 一直卡在 elicitation 上等回答，所以先存下来交给打开的聊天页渲染。
  /// 有界：超过 50 条时淘汰最旧。
  final Map<String, Map<String, dynamic>> _orphanedForms = {};

  /// 已成功提交的裁决（approvalId → 裁决内容）。hub 断连重连后会重发卡片；
  /// 若裁决其实已提交成功（只是 resp 没到达 hub），重发的卡片用这里存储的
  /// 裁决自动应答，不再计数、不再弹卡（E24）。
  /// 有界：超过 50 条时淘汰最旧。
  final Map<String, ({String actionId, String? label})> _submittedApprovals =
      {};

  /// 已提交的 AskUserQuestion 表单。重连重发 `agent_form_req` 时用它自动回填。
  final Map<String, Map<String, dynamic>> _submittedForms = {};

  /// 已经交到卡片上的提问（approvalId → 原来那一轮的 requestId）。
  ///
  /// 这一轮已经收束，卡片却还该留着等用户以后点。它不能继续占用
  /// [_approvalToRequest] / [_orphanedApprovals] / [_orphanedForms] 的额度：
  /// 那三张表会被 `agent_done` / `turn_ended` 收掉。作答后由 App 另开一轮，
  /// 不再往旧通道回。有界：超过 50 条时淘汰最旧。
  final Map<String, String> _deferredForms = {};

  /// 断连挂起期间用户本地取消的 turn（requestId → peerId）。
  /// 重连后对这些 requestId 补发 agent_cancel 而非 resume_req。
  /// 有界：超过 100 条时淘汰最旧。
  final Map<String, String> _cancelledWhileSuspended = {};

  /// 因断连而不可恢复地失败的 turn 所属的「peerId::remoteAgentId」。
  /// 这些 turn 的完整结果可能仍留在远端 transcript（hub 的 turn registry
  /// 或上游 agent 的会话历史）—— 重连后通过增量历史同步补回对话。
  /// 有界：超过 50 条时淘汰最旧。
  final Set<String> _reconcileNeeded = <String>{};

  /// 主机补发的终态帧只处理一次：每次重连都会重发同一批，
  /// 不去重会让聊天页反复拉历史。
  final Set<String> _orphanTerminalSeen = <String>{};

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

  /// 孤儿表单（重连后补发、但没有活动 turn 可挂）交给打开的聊天页渲染。
  /// 载荷形状与 [PeerChatRequest.onForm] 一致，另外带 `peer_id` /
  /// `remote_agent_id` 用于路由，前端只需照常喂给 FormBubble。
  final _orphanFormController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get orphanFormEvents =>
      _orphanFormController.stream;

  /// 主机不再等这张卡片了：等不到回答（`timeout`，按默认继续往下跑）或者回合
  /// 被停止（`cancelled`）。卡片本身不会从屏幕上消失 —— 它是「问过但没答」的
  /// 记录，留着才诚实 —— 但要收起可点态，不然用户点一下只会撞上「已失效」。
  ///
  /// 只带 `approval_id`：卡片落在哪条消息上由 UI 按 id 反查（和 cli 审批卡
  /// 一样），DM / 群聊 / 孤儿卡三条路径就都不用再传路由信息。
  /// 单例上的长期流，[stop] 不关闭它。
  final _interactionClosedController =
      StreamController<({String approvalId, String reason})>.broadcast();
  Stream<({String approvalId, String reason})> get interactionClosedEvents =>
      _interactionClosedController.stream;

  /// 一张已经在回合内等超时的卡片：回合结束，卡片留着。
  /// 聊天页据此把内存里的卡标成 deferred（仍可点），不要收成作废态。
  /// 单例上的长期流，[stop] 不关闭它。
  final _formDeferredController =
      StreamController<({String approvalId, String requestId})>.broadcast();
  Stream<({String approvalId, String requestId})> get formDeferredEvents =>
      _formDeferredController.stream;

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
      if (_pouchLoginReady(peerId)) _greetHost(peerId);
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
    _orphanedForms.clear();
    _submittedApprovals.clear();
    _submittedForms.clear();
    _deferredForms.clear();
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
    for (final c in _pendingFsBrowse.values) {
      if (!c.isCompleted) {
        c.complete(const PeerFsBrowseResult(ok: false, error: 'stopped'));
      }
    }
    _pendingFsBrowse.clear();
    for (final c in _pendingEngineStatus.values) {
      if (!c.isCompleted) {
        c.complete(const PeerEngineStatusResult(ok: false, error: 'stopped'));
      }
    }
    _pendingEngineStatus.clear();
    for (final c in _pendingEngineControl.values) {
      if (!c.isCompleted) {
        c.complete(const PeerEngineControlResult(ok: false, error: 'stopped'));
      }
    }
    _pendingEngineControl.clear();
    _recentlyCreatedAgents.clear();
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

  /// 这路会话上还有没写完的回复，下一条应该排队。
  ///
  /// 已经交到主机队列里的消息（heldOnHost）也算挡住：要保持先后顺序。
  /// 正文已经停住、没有审批也没有工具时返回 false，调用方应直接发送。
  bool followUpBlockedByChannel(String channelId) {
    if (channelId.isEmpty) return false;
    final now = DateTime.now();
    for (final p in _pending.values) {
      if (p.completer.isCompleted || p.channelId != channelId) continue;
      if (p.heldOnHost) return true;
      if (!settledReplyLetsFollowUp(
        hasAnswer: p.answerContent.trim().isNotEmpty,
        openApprovals: p.openApprovals,
        idle: now.difference(p.idleSince),
      )) {
        return true;
      }
    }
    return false;
  }

  /// 把已经写完的在途回合按现有正文收掉，好让下一条马上发出去。
  ///
  /// 不走用户停止：停止会把气泡改成「已停止」。这里只是引擎还没交正式收尾。
  void completeSettledTurns(String channelId, {String fallbackAnswer = ''}) {
    if (channelId.isEmpty) return;
    final now = DateTime.now();
    final ready = <String>[];
    for (final entry in _pending.entries) {
      final pending = entry.value;
      if (pending.completer.isCompleted ||
          pending.channelId != channelId ||
          pending.heldOnHost) {
        continue;
      }
      final answer = pending.answerContent.trim().isNotEmpty
          ? pending.answerContent
          : fallbackAnswer;
      if (!settledReplyLetsFollowUp(
        hasAnswer: answer.trim().isNotEmpty,
        openApprovals: pending.openApprovals,
        idle: now.difference(pending.idleSince),
      )) {
        continue;
      }
      ready.add(entry.key);
    }
    for (final id in ready) {
      final pending = _pending[id];
      if (pending == null) continue;
      final answer = pending.answerContent.trim().isNotEmpty
          ? pending.answerContent
          : fallbackAnswer;
      _finishPending(id, {'content': answer});
    }
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
    _stopCatchUp(p);
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

  /// Test seam: when set, control frames that tests need to capture or ack
  /// ([_abortPendingTurn]'s `agent_cancel`, [submitForm]'s `agent_form_resp`)
  /// route here instead of [PeerConnectionManager], letting unit tests run
  /// without a live peer connection.
  @visibleForTesting
  Future<bool> Function(String peerId, Map<String, dynamic> json)?
      debugSendControlOverride;

  /// Test seam: shrink the resume-response watchdog so unit tests can observe
  /// resend/retry behavior without waiting [resumeResponseTimeout] for real.
  @visibleForTesting
  Duration? debugResumeResponseTimeoutOverride;

  /// Test seam: shrink the post-send delivery probe delay.
  @visibleForTesting
  Duration? debugDeliveryProbeDelayOverride;

  /// Test seam: shrink the `agent_queued` ack wait.
  @visibleForTesting
  Duration? debugQueueAckTimeoutOverride;

  /// Test seam: shrink the post-reconnect catch-up probe interval.
  @visibleForTesting
  Duration? debugReconnectCatchUpIntervalOverride;

  /// Test seam: schedule the post-send delivery probe for a seeded turn.
  @visibleForTesting
  void debugScheduleDeliveryProbe(
    String requestId, {
    required String peerId,
  }) {
    final p = _pending[requestId];
    if (p == null) return;
    _scheduleDeliveryProbe(requestId, p, peerId);
  }

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

  /// 单测里没有走 [start]，但要观察「通道装上之后拉名单」。
  @visibleForTesting
  bool debugTreatAsRunning = false;

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
    debugTreatAsRunning = false;
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
    for (final c in _pendingManage.values) {
      if (!c.isCompleted) {
        c.complete(const PeerAgentManageResult(ok: false, error: 'stopped'));
      }
    }
    _pendingManage.clear();
    for (final c in _pendingFsBrowse.values) {
      if (!c.isCompleted) {
        c.complete(const PeerFsBrowseResult(ok: false, error: 'stopped'));
      }
    }
    _pendingFsBrowse.clear();
    for (final c in _pendingEngineStatus.values) {
      if (!c.isCompleted) {
        c.complete(const PeerEngineStatusResult(ok: false, error: 'stopped'));
      }
    }
    _pendingEngineStatus.clear();
    for (final c in _pendingEngineControl.values) {
      if (!c.isCompleted) {
        c.complete(const PeerEngineControlResult(ok: false, error: 'stopped'));
      }
    }
    _pendingEngineControl.clear();
    for (final waiters in _agentListWaiters.values) {
      for (final c in waiters) {
        if (!c.isCompleted) c.complete();
      }
    }
    _agentListWaiters.clear();
    _recentlyCreatedAgents.clear();
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
    Map<String, dynamic>? agentChatFrame,
  }) {
    final p = _PendingRequest(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      channelId: channelId,
      sessionId: sessionId,
      localAgentId: localAgentId,
    );
    p.agentChatFrame = agentChatFrame;
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

  /// Test seam: 这张表单是否已经存成了待渲染的孤儿卡。
  @visibleForTesting
  bool debugIsOrphanFormBuffered(String approvalId) =>
      _orphanedForms.containsKey(approvalId);

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

  /// 测试用：这张卡片还在本地账簿里（未答、未作废）。
  bool debugIsCardActive(String approvalId) =>
      _approvalToRequest.containsKey(approvalId) ||
      _orphanedApprovals.containsKey(approvalId) ||
      _orphanedForms.containsKey(approvalId);

  /// Rebind UI/persistence callbacks on a hydrated turn after process restart.
  void attachPendingHandlers(
    String requestId, {
    void Function(String chunk)? onChunk,
    void Function(Map<String, dynamic>)? onMetadata,
    void Function(Map<String, dynamic>)? onActionConfirmation,
    void Function(Map<String, dynamic>)? onForm,
  }) {
    final p = _pending[requestId];
    if (p == null) return;
    p.onChunk = onChunk;
    p.onMetadata = onMetadata;
    p.onActionConfirmation = onActionConfirmation;
    p.onForm = onForm;
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

    final beginSent = await PeerConnectionManager.instance.sendControl(
      peerId,
      {
        'type': 'agent_file_begin',
        'agent_id': remoteAgentId,
        'file_id': fileId,
        'file_name': attachment.fileName,
        'mime_type': attachment.mimeType,
        'file_type': attachment.semanticType,
        'size': attachment.sizeBytes,
        if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      },
      // 切网后第一条帧最容易撞上半开的旧连接：等重连再发，避免整个附件
      // 推送直接失败。后续分片已在同一条新连接上，保持 fail-fast。
      waitForReconnect: _controlReconnectWait,
    );
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
  /// 连接不可用时（典型：刚切网）会主动触发重连并等待 [_controlReconnectWait]，
  /// 连上后补发；超时才抛错。等待期间通过 [onReconnecting] 通知 UI。
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
    void Function(Map<String, dynamic>)? onForm,

    /// Fired once [requestId] is allocated, before the control frame is sent.
    void Function(String requestId)? onRequestStarted,

    /// 发送时连接不可用 → 等待重连的进度回调：`(1, 1)` 进入等待，
    /// `(0, 0)` 等待结束（连上并发出，或最终失败）。复用 ACP 的重连提示。
    void Function(int attempt, int total)? onReconnecting,
    ACPCancellationToken? cancelToken,
    String? localAgentId,
    String? channelId,
    String? userMessageId,
    String? userId,
    String? userName,
    String? agentName,

    /// 这条引用回复的是哪一条（本机落库 id）。主机存裸 id 并在事件与历史里
    /// 回放，换台设备也能指回同一条。
    String? replyToId,

    /// 引用时选中的那段文字，被引用的那条不在本地时靠它兜底。
    String? replyQuoteText,
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
      onForm: onForm,
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

    final deviceInfo = await ClientDeviceInfo.current();
    // 留一份原始帧：投递确认失败时原样补发，request_id 不变。
    pending.agentChatFrame = {
      'type': 'agent_chat',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'message': message,
      // 本端落库用户消息用的 id。主机拿它当这条记录的 id，回传事件与
      // 本机 SQLite 行就是同一条，不会在屏幕上叠成两条一样的用户消息。
      // 本机行是主机形态（`peerhist_*`），上行要还原成裸 id —— 前缀归主机加。
      if (userMessageId != null && userMessageId.isNotEmpty)
        'user_message_id': bareMessageId(userMessageId),
      // 引用回复：同样只发裸 id，前缀归本机自己加回来。
      if (replyToId != null && replyToId.isNotEmpty)
        'reply_to_id': bareMessageId(replyToId),
      if (replyQuoteText != null && replyQuoteText.isNotEmpty)
        'reply_quote_text': replyQuoteText,
      // 把本端会话 id 透传给对端，使对端按会话隔离历史：本端「新开会话」
      // 在对端也得到一条干净、无历史的新会话。
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (history != null && history.isNotEmpty) 'history': history,
      if (attachmentRefs != null) 'attachments': attachmentRefs,
      if (extraTools != null && extraTools.isNotEmpty)
        'extra_tools': extraTools,
      ...deviceInfo.toWireFields(),
    };
    var waitingForReconnect = false;
    final sent = await PeerConnectionManager.instance.sendControl(
      peerId,
      pending.agentChatFrame!,
      // 切网后 connectivity 监听的重连有 800ms 去抖 + 探活，用户往往等不到。
      // 这里主动拉起重连并最多等 [_controlReconnectWait]，连上就补发。
      waitForReconnect: _controlReconnectWait,
      onWaitingForReconnect: () {
        waitingForReconnect = true;
        onReconnecting?.call(1, 1);
      },
      abortWhen: () => cancelToken?.isCancelled == true,
    );
    if (waitingForReconnect) onReconnecting?.call(0, 0);

    if (!sent) {
      final cancelled = cancelToken?.isCancelled == true;
      _pending.remove(requestId);
      _clearPersistedTurn(requestId);
      if (cancelled) {
        // 用户在等待重连期间点了停止：不是发送失败，按已取消收尾，别弹错误。
        if (!pending.completer.isCompleted) {
          pending.completer.complete(
            PeerChatResult(content: '[Stopped]', requestId: requestId),
          );
        }
        return PeerChatResult(content: '[Stopped]', requestId: requestId);
      }
      throw Exception('配对设备未连接，无法发送');
    }

    _log.info(
      'agent_chat sent requestId=$requestId peerId=$peerId '
      'remoteAgentId=$remoteAgentId sessionId=${sessionId ?? '-'} '
      'attachments=${attachmentRefs?.length ?? 0}',
      tag: 'PeerAgentClient',
    );
    _scheduleDeliveryProbe(requestId, pending, peerId);

    final result = await _awaitTurnCompletion(requestId, pending, peerId);
    return PeerChatResult(
      content: result.content,
      metadata: result.metadata,
      requestId: requestId,
    );
  }

  /// 会话正忙时把下一条交给主机排队。返回 true 表示主机先收下了。
  Future<bool> enqueueChat({
    required String peerId,
    required String remoteAgentId,
    required String requestId,
    required String message,
    String? sessionId,
    String? channelId,
    String? localAgentId,
    String? userId,
    String? userName,
    String? agentName,
    String? userMessageId,
    List<AttachmentData>? attachments,

    /// 这条引用回复的是哪一条（本机落库 id）；上行只发裸 id。
    String? replyToId,

    /// 引用时选中的那段文字。
    String? replyQuoteText,
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
    final ack = Completer<bool>();
    final pending = _PendingRequest(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId ?? '',
      channelId: channelId ?? '',
      sessionId: sessionId ?? '',
      userId: userId ?? '',
      userName: userName ?? '',
      agentName: agentName ?? '',
      userMessageId: userMessageId ?? '',
    );
    pending.heldOnHost = true;
    pending.parkedText = message;
    pending.queueAck = ack;
    _pending[requestId] = pending;
    unawaited(pending.completer.future.then((result) {
      unawaited(_saveParkedReply(pending, requestId, result.content));
    }).catchError((Object _) {
      ChatService().dropQueuedMessage(requestId);
    }));
    final deviceInfo = await ClientDeviceInfo.current();
    final frame = <String, dynamic>{
      'type': 'agent_chat',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'message': message,
      if (userMessageId != null && userMessageId.isNotEmpty)
        'user_message_id': bareMessageId(userMessageId),
      if (replyToId != null && replyToId.isNotEmpty)
        'reply_to_id': bareMessageId(replyToId),
      if (replyQuoteText != null && replyQuoteText.isNotEmpty)
        'reply_quote_text': replyQuoteText,
      if (sessionId != null && sessionId.isNotEmpty) 'session_id': sessionId,
      if (channelId != null && channelId.isNotEmpty) 'channel_id': channelId,
      if (attachmentRefs != null) 'attachments': attachmentRefs,
      ...deviceInfo.toWireFields(),
    };
    final override = debugSendControlOverride;
    final sent = override != null
        ? await override(peerId, frame)
        : await PeerConnectionManager.instance.sendControl(
            peerId,
            frame,
            waitForReconnect: _controlReconnectWait,
          );
    if (!sent) {
      _pending.remove(requestId);
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(Exception('配对设备未连接，无法发送'));
      }
      throw Exception('配对设备未连接，无法发送');
    }
    unawaited(_awaitTurnCompletion(requestId, pending, peerId));
    try {
      return await ack.future.timeout(_effectiveQueueAckTimeout);
    } on TimeoutException {
      // 确认帧可能正好丢在断线上。主机会把已经受理、但还没开跑的
      // request 也映射成 streaming，所以先 resume 对账一次再判死：
      // 直接报失败会让主机照跑的那条消息被用户重发一遍。
      if (!pending.completer.isCompleted && !ack.isCompleted) {
        if (!pending.resumeInFlight) {
          pending.resumeInFlight = true;
          pending.resumePurpose = _ResumePurpose.deliveryProbe;
          pending.resumeBaseLength = pending.receivedLength;
          final probed = await _sendResumeReq(peerId, requestId, pending);
          if (!probed) {
            // 连接此刻不可用，帧可能只是没送出去 —— 保留排队态，等重连。
            pending.resumeInFlight = false;
            pending.resumePurpose = _ResumePurpose.none;
            pending.resumeBaseLength = null;
            return true;
          }
          // 应答由 _onTurnResumeResp 收口：非 lost → ack(true)，
          // lost → ack(false)。看门狗只负责没应答时复位标志。
          _watchResumeResponse(
            peerId,
            requestId,
            0,
            failOnExhausted: false,
          );
        }
        try {
          return await ack.future.timeout(_effectiveResumeResponseTimeout);
        } on TimeoutException {
          // 连得上却没回音：先保留排队态，交给重连后的 resume 对账。
          return true;
        }
      }
      _pending.remove(requestId);
      if (!ack.isCompleted) {
        ack.completeError(TimeoutException('主机没有收下排队消息'));
      }
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(TimeoutException('主机没有收下排队消息'));
      }
      rethrow;
    }
  }

  Future<void> _saveParkedReply(
    _PendingRequest pending,
    String requestId,
    String reply,
  ) async {
    ChatService().releaseQueuedMessage(requestId);
    final channelId = pending.channelId;
    final text = pending.parkedText;
    if (channelId.isEmpty || text == null || text.trim().isEmpty) {
      if (channelId.isNotEmpty) {
        await ChatService().completeQueuedPeerTurn(channelId);
      }
      return;
    }
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      await ChatService().completeQueuedPeerTurn(channelId);
      return;
    }
    final db = getIt<LocalDatabaseService>();
    final userMessageId =
        pending.userMessageId.isEmpty ? requestId : pending.userMessageId;
    final replyId = 'peerhist_$requestId';
    try {
      await db.createMessage(
        id: userMessageId,
        channelId: channelId,
        senderId: pending.userId,
        senderType: 'user',
        senderName: pending.userName,
        content: text,
        metadata: ClientDeviceInfo.stampMetadata(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await db.createMessage(
        id: replyId,
        channelId: channelId,
        senderId: pending.localAgentId.isEmpty
            ? pending.remoteAgentId
            : pending.localAgentId,
        senderType: 'agent',
        senderName: pending.agentName,
        content: reply,
        replyToId: userMessageId,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if ('$requestId-reply' != replyId) {
        await db.deleteMessage('$requestId-reply');
      }
    } catch (error) {
      _log.warning('save parked reply failed: $error', tag: _tag);
    }
    await ChatService().completeQueuedPeerTurn(channelId);
    ChatService().notifyChannelUpdate(channelId);
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
      if (pending.heldOnHost) return;
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

  /// 主机的补发帧到达时，本机已经找不到这条 turn 的在途记录。
  ///
  /// 不能把 `content` 直接当新消息插入：同一条回复在远端历史里已经有了，
  /// 直接插会重复；而且没有 channelId 也落不到正确的会话。这里只发一次
  /// 历史对账信号，由聊天页从远端 transcript 补齐。
  void _reconcileOrphanTerminal(
    String requestId,
    Map<String, dynamic> data,
    String? fromPeerId,
  ) {
    final status = data['status'] as String? ?? '';
    if (status != 'done' && status != 'error') return;
    final remoteAgentId = (data['agent_id'] as String? ?? '').trim();
    final peerId = fromPeerId ?? _requestAgents[requestId]?.peerId;
    if (peerId == null || remoteAgentId.isEmpty) return;
    if (!_orphanTerminalSeen.add(requestId)) return;
    if (_orphanTerminalSeen.length > 200) {
      _orphanTerminalSeen.remove(_orphanTerminalSeen.first);
    }
    final key = '$peerId::$remoteAgentId';
    _log.info(
      'orphan terminal frame requestId=$requestId status=$status '
      '→ request history reconcile for $key',
      tag: _tag,
    );
    _reconcileController.add(key);
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
    _stopCatchUp(p);
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

  /// 收到主机帧 → 标记该 turn 已被主机接收，并取消待发的投递探活。
  void _noteHostTurnSignal(Map<String, dynamic> data) {
    final requestId = data['request_id'];
    if (requestId is! String) return;
    final p = _pending[requestId];
    if (p == null || p.heardFromHost) return;
    p.heardFromHost = true;
    p.deliveryProbeTimer?.cancel();
    p.deliveryProbeTimer = null;
  }

  void _onControl(PeerControlEvent event) {
    // 主机对某个在途 turn 发出的任何业务帧，都说明它收到了 agent_chat。
    // resume 应答本身就是投递确认的答案，交给 _onTurnResumeResp 处理。
    if (event.type != 'agent_turn_resume_resp') {
      _noteHostTurnSignal(event.data);
    }
    switch (event.type) {
      case 'agent_list_resp':
        unawaited(_onAgentList(event.peerId, event.data));
        break;
      case 'pouch_login_required':
        // 主机重启后不认旧登录。挂着的模型、实例管理、目录浏览请求不会再有回包，
        // 立刻放开，等重新登录后重发。
        _abandonModelFetches();
        _abandonManageAndBrowseOnLoginRequired();
        break;
      case 'agent_chunk':
        _onChunk(event.data);
        break;
      case 'agent_queued':
        _onAgentQueued(event.data);
        break;
      case 'pouch_turn_event':
        PouchTurnRelay.instance.onEvent(event.data);
        break;
      case 'pouch_file_ack':
        PouchTurnRelay.instance.onFileAck(event.data);
        break;
      case 'pouch_pair_resp':
      case 'pouch_peer_list_resp':
      case 'pouch_peer_remove_resp':
        PouchPairRelay.instance.onResponse(event.data);
        break;
      case 'agent_turn_resume_resp':
        _onTurnResumeResp(event.data, fromPeerId: event.peerId);
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
      case 'peer_busy':
        // 主机上行队列满，这一帧没有收下（agent_chat 会走 agent_error）。
        // 请求方各自按超时失败；留一条日志便于区分主机过载和网络问题。
        _log.warning(
          '主机正忙，已拒收一帧：${event.data['message'] ?? ''}',
          tag: _tag,
        );
        break;
      case 'agent_approval_req':
        _onApprovalReq(event.peerId, event.data);
        break;
      case 'agent_form_req':
        _onFormReq(event.peerId, event.data);
        break;
      case 'agent_form_deferred':
        unawaited(_onFormDeferred(event.peerId, event.data));
        break;
      case 'agent_interaction_closed':
        _onInteractionClosed(event.data);
        break;
      case 'session_create_req':
        unawaited(_onSessionCreateReq(event.peerId, event.data));
        break;
      case 'cli_execute_req':
        unawaited(_onCliExecuteReq(event.peerId, event.data));
        break;
      case 'cmd.invoke':
        unawaited(_onCmdInvoke(event.peerId, event.data));
        break;
      case 'approval.req':
      case 'approval.closed':
      case 'approval.ack':
        commandApprovals.apply(event.data);
        break;
      case 'agent_commands_resp':
        _onCommandsResp(event.peerId, event.data);
        break;
      case 'agent_meta_changed':
        _onAgentMetaChanged(event);
        break;
      case 'agent_sessions_resp':
        _onSessionsResp(event.peerId, event.data);
        break;
      case 'agent_sessions_digest_resp':
        _onSessionsDigestResp(event.peerId, event.data);
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
      case 'she_model_set_resp':
        _onSheModelSetResp(event.peerId, event.data);
        break;
      case 'she_catalog_put_resp':
        _onSheCatalogPutResp(event.data);
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
      case 'agent_client_sessions_sync_set_resp':
        _onClientSessionsSyncSetResp(event.data);
        break;
      case 'agent_session_open_resp':
        _completeHostEmpty(_pendingHostSessionOpen, event.data);
        break;
      case 'agent_session_drop_resp':
        _completeHostEmpty(_pendingHostSessionDrop, event.data);
        break;
      case 'agent_session_delete_resp':
        _completeHostEmpty(_pendingHostSessionDelete, event.data);
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
      case 'engine_status_resp':
        _onEngineStatusResp(event.data);
        break;
      case 'engine_control_resp':
        _onEngineControlResp(event.data);
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

  /// 新建或打开空会话时提前通知主机后台拉起 ACP 引擎子进程并预热 `session/new`，
  /// 用户输入完首条消息点击发送时即可直接命中热会话。
  Future<void> warmSession({
    required RemoteAgent agent,
    required String channelId,
  }) async {
    if (!agent.isPeerAgent || relaysHostSheTurn(agent)) return;
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (peerId == null ||
        peerId.isEmpty ||
        remoteAgentId == null ||
        remoteAgentId.isEmpty) {
      return;
    }
    if (!_peerIsConnected(peerId)) return;
    final sessionId = hostSessionIdForChannel(channelId);
    if (sessionId.isEmpty) return;
    try {
      await _sendMetaControl(peerId, {
        'type': 'agent_session_warm',
        'agent_id': remoteAgentId,
        'session_id': sessionId,
      });
    } catch (_) {}
  }

  /// 把刚建的空会话登记到主机。成功后其他已登录客户端会收到名单变化。
  Future<bool> openHostSession({
    required RemoteAgent agent,
    required String channelId,
  }) {
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (!agent.isPeerAgent ||
        peerId == null ||
        peerId.isEmpty ||
        remoteAgentId == null ||
        remoteAgentId.isEmpty) {
      return Future<bool>.value(false);
    }
    final sessionId = hostSessionIdForChannel(channelId);
    if (!_plainHostSessionId(sessionId)) return Future<bool>.value(false);
    final key = '$peerId::$remoteAgentId::$sessionId';
    final existing = _hostEmptyOpens[key];
    if (existing != null) return existing;
    final future = _openHostSession(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      channelId: channelId,
      sessionId: sessionId,
    );
    _hostEmptyOpens[key] = future;
    return future.whenComplete(() => _hostEmptyOpens.remove(key));
  }

  Future<bool> _openHostSession({
    required String peerId,
    required String remoteAgentId,
    required String channelId,
    required String sessionId,
  }) async {
    if (!_peerIsConnected(peerId)) return false;
    final requestId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingHostSessionOpen[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'agent_session_open_req',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'session_id': sessionId,
    });
    if (!sent) {
      _pendingHostSessionOpen.remove(requestId);
      return false;
    }
    final data =
        await _hostEmptyAck(_pendingHostSessionOpen, requestId, completer);
    if (data['ok'] != true) return false;
    ChatService().forgetFreshLocalChannel(channelId);
    _recentlyOpenedHostSessions[channelId] = DateTime.now();
    return true;
  }

  /// 本机要丢掉一条空会话时，先请主机删。主机上已经有消息就留下。
  Future<HostEmptySessionResult> dropHostSession({
    required RemoteAgent agent,
    required String channelId,
  }) async {
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (!agent.isPeerAgent ||
        peerId == null ||
        peerId.isEmpty ||
        remoteAgentId == null ||
        remoteAgentId.isEmpty) {
      return HostEmptySessionResult.absent;
    }
    final sessionId = hostSessionIdForChannel(channelId);
    if (!_plainHostSessionId(sessionId)) return HostEmptySessionResult.absent;
    final key = '$peerId::$remoteAgentId::$sessionId';
    final opening = _hostEmptyOpens[key];
    if (opening != null) {
      final opened = await opening;
      if (!opened) return HostEmptySessionResult.absent;
    } else if (ChatService().isFreshLocalChannel(channelId)) {
      return HostEmptySessionResult.absent;
    }
    if (!_peerIsConnected(peerId)) return HostEmptySessionResult.failed;
    final requestId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingHostSessionDrop[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'agent_session_drop_req',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'session_id': sessionId,
    });
    if (!sent) {
      _pendingHostSessionDrop.remove(requestId);
      return HostEmptySessionResult.failed;
    }
    final data =
        await _hostEmptyAck(_pendingHostSessionDrop, requestId, completer);
    if (data['ok'] == true) {
      return data['removed'] == true
          ? HostEmptySessionResult.removed
          : HostEmptySessionResult.absent;
    }
    if (data['error'] == 'not_empty') return HostEmptySessionResult.notEmpty;
    return HostEmptySessionResult.failed;
  }

  /// 用户删除会话：请主机按权威数据删／归档。
  ///
  /// 主机连不上时返回 [HostSessionDeleteResult.failed]，调用方不要动本地数据，
  /// 否则下一轮名单同步又会把它建回来。
  Future<HostSessionDeleteResult> deleteHostSession({
    required RemoteAgent agent,
    required String channelId,
  }) async {
    final peerId = agent.sourcePeerId;
    final remoteAgentId = agent.remoteAgentId;
    if (!agent.isPeerAgent ||
        peerId == null ||
        peerId.isEmpty ||
        remoteAgentId == null ||
        remoteAgentId.isEmpty) {
      return HostSessionDeleteResult.absent;
    }
    final sessionId = hostSessionIdForChannel(channelId);
    if (!_plainHostSessionId(sessionId)) {
      return HostSessionDeleteResult.absent;
    }
    final key = '$peerId::$remoteAgentId::$sessionId';
    final opening = _hostEmptyOpens[key];
    if (opening != null) {
      final opened = await opening;
      if (!opened) return HostSessionDeleteResult.absent;
    } else if (ChatService().isFreshLocalChannel(channelId)) {
      // 本机刚建、还没登记到主机，离线也能删。
      return HostSessionDeleteResult.absent;
    }
    if (!_peerIsConnected(peerId)) return HostSessionDeleteResult.failed;
    final requestId = _uuid.v4();
    final completer = Completer<Map<String, dynamic>>();
    _pendingHostSessionDelete[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'agent_session_delete_req',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'session_id': sessionId,
    });
    if (!sent) {
      _pendingHostSessionDelete.remove(requestId);
      return HostSessionDeleteResult.failed;
    }
    final data = await _hostEmptyAck(
      _pendingHostSessionDelete,
      requestId,
      completer,
    );
    if (data['ok'] != true) return HostSessionDeleteResult.failed;
    _recentlyOpenedHostSessions.remove(channelId);
    if (data['removed'] == true) return HostSessionDeleteResult.removed;
    if (data['archived'] == true) return HostSessionDeleteResult.archived;
    return HostSessionDeleteResult.absent;
  }

  bool _plainHostSessionId(String id) {
    if (id.isEmpty || id.length > 120) return false;
    return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(id);
  }

  void _completeHostEmpty(
    Map<String, Completer<Map<String, dynamic>>> pending,
    Map<String, dynamic> data,
  ) {
    final requestId = data['request_id']?.toString();
    if (requestId == null || requestId.isEmpty) return;
    final completer = pending.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data);
    }
  }

  Future<Map<String, dynamic>> _hostEmptyAck(
    Map<String, Completer<Map<String, dynamic>>> pending,
    String requestId,
    Completer<Map<String, dynamic>> completer,
  ) async {
    try {
      return await completer.future.timeout(const Duration(seconds: 5));
    } catch (_) {
      pending.remove(requestId);
      return const {};
    }
  }

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
      } catch (_) {
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
    } catch (_) {
      if (identical(_pendingModels[remoteAgentId], completer)) {
        _pendingModels.remove(remoteAgentId);
      }
      return (list: const PeerModelsList(models: []), completed: false);
    }
  }

  /// 登录失效时，进行中的模型请求不会再收到回包。
  void _abandonModelFetches() {
    final pending = _pendingModels.values.toList();
    _pendingModels.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('pouch_login_required'));
      }
    }
  }

  /// 登录失效时，进行中的实例管理与目录浏览请求已被主机拦下，立刻以
  /// `login_required` 结束单次等待，交由外层等待重登后自动补发一次。
  void _abandonManageAndBrowseOnLoginRequired() {
    final manage = _pendingManage.values.toList();
    _pendingManage.clear();
    for (final completer in manage) {
      if (!completer.isCompleted) {
        completer.complete(const PeerAgentManageResult(
          ok: false,
          error: 'login_required',
          code: 'login_required',
        ));
      }
    }
    final browse = _pendingFsBrowse.values.toList();
    _pendingFsBrowse.clear();
    for (final completer in browse) {
      if (!completer.isCompleted) {
        completer.complete(const PeerFsBrowseResult(
          ok: false,
          error: 'login_required',
          code: 'login_required',
        ));
      }
    }
    final statuses = _pendingEngineStatus.values.toList();
    _pendingEngineStatus.clear();
    for (final completer in statuses) {
      if (!completer.isCompleted) {
        completer.complete(const PeerEngineStatusResult(
          ok: false,
          error: 'login_required',
          code: 'login_required',
        ));
      }
    }
    final controls = _pendingEngineControl.values.toList();
    _pendingEngineControl.clear();
    for (final completer in controls) {
      if (!completer.isCompleted) {
        completer.complete(const PeerEngineControlResult(
          ok: false,
          error: 'login_required',
          code: 'login_required',
        ));
      }
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

  /// 把惜宝的主模型写到 Hub。密钥只在这一帧里走，不进本机 metadata。
  Future<bool> setSheModel({
    required String peerId,
    String model = '',
    String baseUrl = '',
    String apiKey = '',
    String catalogId = '',
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _pendingSheModel[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'she_model_set_req',
      'request_id': requestId,
      if (catalogId.isNotEmpty) 'catalog_id': catalogId,
      'model': model,
      'base_url': baseUrl,
      'api_key': apiKey,
    });
    if (!sent) {
      _pendingSheModel.remove(requestId);
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingSheModel.remove(requestId);
      return false;
    });
  }

  /// 把一条模型写进储物袋名单。密钥留在主机上，响应里不带回。
  ///
  /// [apiKey] 空着时，主机保留同一条模型已有的密钥；同一地址上别的模型
  /// 已有密钥时，新条目也沿用那一把。
  Future<bool> putSheCatalog({
    required String peerId,
    required String displayName,
    required String model,
    required String baseUrl,
    required String apiKey,
    bool select = false,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _pendingSheCatalog[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'she_catalog_put_req',
      'request_id': requestId,
      'display_name': displayName,
      'model': model,
      'base_url': baseUrl,
      'api_key': apiKey,
      if (select) 'select': true,
    });
    if (!sent) {
      _pendingSheCatalog.remove(requestId);
      return false;
    }
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pendingSheCatalog.remove(requestId);
      return false;
    });
  }

  void _onSheCatalogPutResp(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString() ?? '';
    final completer = _pendingSheCatalog.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data['ok'] == true);
    }
  }

  void _onSheModelSetResp(String peerId, Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString() ?? '';
    final completer = _pendingSheModel.remove(requestId);
    final ok = data['ok'] == true;
    unawaited(() async {
      if (ok) await _rememberHostSheModel(peerId, data);
      if (completer != null && !completer.isCompleted) {
        completer.complete(ok);
      }
    }());
  }

  Future<void> _rememberHostSheModel(
    String peerId,
    Map<String, dynamic> data,
  ) async {
    final existing = await _db.getRemoteAgentByEndpoint(
      'peer://$peerId/${SheService.sheId}',
    );
    if (existing == null) return;
    final metadata = Map<String, dynamic>.from(existing.metadata);
    applyHostSheModelMetadata(metadata, data);
    await _db.updateRemoteAgent(
      existing.copyWith(
        metadata: metadata,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    PeerConnectionManager.instance.notifyPeerListChanged();
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

  /// 把「同步官方终端 / IDE 会话」写到主机。成功后主机广播给其他已登录客户端。
  Future<bool> setClientSessionsSync({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required bool enabled,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<bool>();
    _pendingClientSyncSet[requestId] = completer;
    final sent = await _sendMetaControl(peerId, {
      'type': 'agent_client_sessions_sync_set_req',
      'request_id': requestId,
      'agent_id': remoteAgentId,
      'enabled': enabled,
    });
    if (!sent) {
      _pendingClientSyncSet.remove(requestId);
      return false;
    }
    final ok = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingClientSyncSet.remove(requestId);
        return false;
      },
    );
    if (!ok) return false;
    await _applyClientSessionsSync(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId,
      enabled: enabled,
    );
    return true;
  }

  void _onClientSessionsSyncSetResp(Map<String, dynamic> data) {
    final requestId = data['request_id']?.toString();
    if (requestId == null || requestId.isEmpty) return;
    final completer = _pendingClientSyncSet.remove(requestId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data['ok'] == true);
    }
  }

  Future<void> _applyClientSessionsSync({
    required String peerId,
    required String remoteAgentId,
    required String? localAgentId,
    required bool enabled,
  }) async {
    final local = localAgentId ??
        await _localAgentIdForRemote(peerId, remoteAgentId) ??
        remoteAgentId;
    await rememberClientSessionSync(
      localAgentId: local,
      remoteAgentId: remoteAgentId,
      enabled: enabled,
    );
    _writeMeta(
      agentId: remoteAgentId,
      kind: PeerAgentMetaKind.clientSessions,
      payload: {'enabled': enabled},
    );
    if (local != remoteAgentId) {
      _writeMeta(
        agentId: local,
        kind: PeerAgentMetaKind.clientSessions,
        payload: {'enabled': enabled},
      );
    }
    if (!_peerIsConnected(peerId)) return;
    final sessions = await fetchSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    if (sessions == null) return;
    await syncSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: local,
      userId: 'user',
      sessions: sessions,
      pruneToHost: true,
      preserveClientSessions: !enabled,
    );
  }

  /// 主机会话名单变化（`agent_meta_changed kind=sessions`）。
  ///
  /// 帧里只有 `changed_session_id`，名单本身要从主机拉；拉回来按主机视角
  /// 对齐本地频道，主机上没有的本地壳会被清掉（新会话由 [ChatService] 的
  /// fresh 标记保护）。
  Future<void> _mirrorHostSessionList({
    required String peerId,
    required String remoteAgentId,
  }) async {
    if (!_peerIsConnected(peerId)) return;
    final local =
        await _localAgentIdForRemote(peerId, remoteAgentId) ?? remoteAgentId;
    final sessions = await fetchSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    if (sessions == null) return;
    final clientSyncEnabled = await isClientSessionSyncEnabled(
      local,
      remoteAgentId: remoteAgentId,
    );
    await syncSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: local,
      userId: 'user',
      sessions: sessions,
      pruneToHost: true,
      preserveClientSessions: !clientSyncEnabled,
    );
  }

  Future<String?> _localAgentIdForRemote(
    String peerId,
    String remoteAgentId,
  ) async {
    final agents = await _db.getAllRemoteAgents();
    for (final agent in agents) {
      if (agent.metadata['remote_agent_id'] == remoteAgentId &&
          agent.metadata['source_peer_id'] == peerId) {
        return agent.id;
      }
    }
    return null;
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
    final existingReqId = _soulGetRequestByAgent[remoteAgentId];
    if (existingReqId != null) {
      final existingCompleter = _pendingSoulGet[existingReqId];
      if (existingCompleter != null && !existingCompleter.isCompleted) {
        try {
          return await existingCompleter.future.timeout(_soulRelayTimeout);
        } on TimeoutException {
          return null;
        }
      }
    }
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

  void applyHubAgentMeta({
    required String peerId,
    required String agentId,
    required String kind,
    required Map<String, dynamic> data,
  }) {
    _onAgentMetaChanged(PeerControlEvent(
      peerId: peerId,
      data: {
        'type': 'agent_meta_changed',
        'agent_id': agentId,
        'kind': kind,
        'data': data,
      },
    ));
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
      case 'she_model':
        unawaited(_rememberHostSheModel(event.peerId, data));
      case PeerAgentMetaKind.commands:
        _applyCommandsResp(
          agentId,
          _parseCommandList(data['commands']),
          peerId: event.peerId,
          completePending: false,
          rev: rev,
        );
      case PeerAgentMetaKind.clientSessions:
        final enabled = data['enabled'] == true;
        unawaited(_applyClientSessionsSync(
          peerId: event.peerId,
          remoteAgentId: agentId,
          localAgentId: null,
          enabled: enabled,
        ));
      case PeerAgentMetaKind.sessions:
        unawaited(_mirrorHostSessionList(
          peerId: event.peerId,
          remoteAgentId: agentId,
        ));
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

  Future<PeerAgentMetaCacheEntry?> _getPeerAgentMetaRow(
    String agentId,
    String kind,
  ) async {
    final direct = await _db.getPeerAgentMeta(agentId, kind);
    if (direct != null) return direct;
    final agent = await _db.getRemoteAgentById(agentId);
    final remoteId = agent == null
        ? null
        : (relaysHostSheTurn(agent)
            ? hostSheTurnAgentId(agent)
            : agent.remoteAgentId);
    if (remoteId != null && remoteId.isNotEmpty && remoteId != agentId) {
      return _db.getPeerAgentMeta(remoteId, kind);
    }
    return null;
  }

  Future<PeerModelsList?> _readCachedModels(String agentId) async {
    try {
      final row = await _getPeerAgentMetaRow(agentId, PeerAgentMetaKind.models);
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
      final row = await _getPeerAgentMetaRow(agentId, PeerAgentMetaKind.modes);
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
      final row = await _getPeerAgentMetaRow(agentId, PeerAgentMetaKind.soul);
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
  ///
  /// [nodeId] 是工作节点指纹：请求仍发给主机连接，由主机转给这个节点。
  Future<bool> _sendInteractiveControl(
    String peerId,
    Map<String, dynamic> json, {
    required bool waitForReconnect,
  }) {
    final override = debugSendControlOverride;
    if (override != null) return override(peerId, json);
    return PeerConnectionManager.instance.sendControl(
      peerId,
      json,
      waitForReconnect: waitForReconnect ? _controlReconnectWait : null,
    );
  }

  Future<PeerAgentManageResult> manageAgents({
    required String peerId,
    required String op,
    String? nodeId,
    String? agentId,
    bool? enabled,
    String? cwd,
    List<String>? additionalDirectories,
    String? engine,
    String? name,
    String? sessionMode,
    Duration timeout = const Duration(seconds: 15),
    bool waitForReconnect = true,
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
    try {
      return await sendWithReloginRetry(
        retryOnRelogin: true,
        reloginGeneration: () => PouchLoginKeeper.instance.reloginGeneration,
        waitForRelogin: (seen) =>
            PouchLoginKeeper.instance.waitForRelogin(seenGeneration: seen),
        send: () => _manageAgentsOnce(
          peerId: peerId,
          op: op,
          nodeId: nodeId,
          agentId: agentId,
          enabled: enabled,
          cwd: cwd,
          additionalDirectories: additionalDirectories,
          engine: engine,
          name: name,
          sessionMode: sessionMode,
          timeout: timeout,
          waitForReconnect: waitForReconnect,
        ),
      );
    } on PouchLoginRequired {
      return const PeerAgentManageResult(
        ok: false,
        error: 'login_required',
        code: 'login_required',
      );
    } on Exception {
      return const PeerAgentManageResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    }
  }

  Future<PeerAgentManageResult> _manageAgentsOnce({
    required String peerId,
    required String op,
    String? nodeId,
    String? agentId,
    bool? enabled,
    String? cwd,
    List<String>? additionalDirectories,
    String? engine,
    String? name,
    String? sessionMode,
    required Duration timeout,
    required bool waitForReconnect,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerAgentManageResult>();
    _pendingManage[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'agent_manage_req',
      'request_id': requestId,
      'op': op,
      if (nodeId != null) 'node_id': nodeId,
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
    final sent = await _sendInteractiveControl(
      peerId,
      payload,
      waitForReconnect: waitForReconnect,
    );
    if (!sent) {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(ok: false, error: 'offline');
    }
    final result = await completer.future.timeout(timeout, onTimeout: () {
      _pendingManage.remove(requestId);
      return const PeerAgentManageResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    });
    if (result.code == 'login_required') {
      throw const PouchLoginRequired();
    }
    return result;
  }

  /// 读主机缓存的引擎目录和运行时占用。
  ///
  /// [nodeId] 不为空时由主机转给工作节点；回包里的实例 id 已经带上节点后缀。
  /// [refresh] 要求主机重扫 PATH，页面手动刷新时才用。
  Future<PeerEngineStatusResult> engineStatus({
    required String peerId,
    String? nodeId,
    bool refresh = false,
    Duration timeout = const Duration(seconds: 8),
    bool waitForReconnect = false,
  }) async {
    try {
      return await sendWithReloginRetry(
        retryOnRelogin: true,
        reloginGeneration: () => PouchLoginKeeper.instance.reloginGeneration,
        waitForRelogin: (seen) =>
            PouchLoginKeeper.instance.waitForRelogin(seenGeneration: seen),
        send: () => _engineStatusOnce(
          peerId: peerId,
          nodeId: nodeId,
          refresh: refresh,
          timeout: timeout,
          waitForReconnect: waitForReconnect,
        ),
      );
    } on PouchLoginRequired {
      return const PeerEngineStatusResult(
        ok: false,
        error: 'login_required',
        code: 'login_required',
      );
    } on Exception {
      return const PeerEngineStatusResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    }
  }

  Future<PeerEngineStatusResult> _engineStatusOnce({
    required String peerId,
    String? nodeId,
    required bool refresh,
    required Duration timeout,
    required bool waitForReconnect,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerEngineStatusResult>();
    _pendingEngineStatus[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'engine_status_req',
      'request_id': requestId,
      if (nodeId != null) 'node_id': nodeId,
      if (refresh) 'refresh': true,
    };
    final sent = await _sendInteractiveControl(
      peerId,
      payload,
      waitForReconnect: waitForReconnect,
    );
    if (!sent) {
      _pendingEngineStatus.remove(requestId);
      return const PeerEngineStatusResult(ok: false, error: 'offline');
    }
    final result = await completer.future.timeout(timeout, onTimeout: () {
      _pendingEngineStatus.remove(requestId);
      return const PeerEngineStatusResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    });
    if (result.code == 'login_required') {
      throw const PouchLoginRequired();
    }
    return result;
  }

  /// 管理页的手动操作：`kill_instance` 杀掉实例全部子进程，
  /// `kill_session` 只结束一段会话（运行中的回合和排队的消息）。
  Future<PeerEngineControlResult> engineControl({
    required String peerId,
    required String op,
    required String instanceId,
    String? nodeId,
    String? sessionKey,
    Duration timeout = const Duration(seconds: 10),
    bool waitForReconnect = false,
  }) async {
    try {
      return await sendWithReloginRetry(
        retryOnRelogin: true,
        reloginGeneration: () => PouchLoginKeeper.instance.reloginGeneration,
        waitForRelogin: (seen) =>
            PouchLoginKeeper.instance.waitForRelogin(seenGeneration: seen),
        send: () => _engineControlOnce(
          peerId: peerId,
          op: op,
          instanceId: instanceId,
          nodeId: nodeId,
          sessionKey: sessionKey,
          timeout: timeout,
          waitForReconnect: waitForReconnect,
        ),
      );
    } on PouchLoginRequired {
      return const PeerEngineControlResult(
        ok: false,
        error: 'login_required',
        code: 'login_required',
      );
    } on Exception {
      return const PeerEngineControlResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    }
  }

  Future<PeerEngineControlResult> _engineControlOnce({
    required String peerId,
    required String op,
    required String instanceId,
    String? nodeId,
    String? sessionKey,
    required Duration timeout,
    required bool waitForReconnect,
  }) async {
    final requestId = _uuid.v4();
    final completer = Completer<PeerEngineControlResult>();
    _pendingEngineControl[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'engine_control_req',
      'request_id': requestId,
      'op': op,
      'instance_id': instanceId,
      if (nodeId != null) 'node_id': nodeId,
      if (sessionKey != null) 'session_key': sessionKey,
    };
    final sent = await _sendInteractiveControl(
      peerId,
      payload,
      waitForReconnect: waitForReconnect,
    );
    if (!sent) {
      _pendingEngineControl.remove(requestId);
      return const PeerEngineControlResult(ok: false, error: 'offline');
    }
    final result = await completer.future.timeout(timeout, onTimeout: () {
      _pendingEngineControl.remove(requestId);
      return const PeerEngineControlResult(
        ok: false,
        unsupported: true,
        error: 'timeout',
      );
    });
    if (result.code == 'login_required') {
      throw const PouchLoginRequired();
    }
    return result;
  }

  /// Register a new agent on the host. Refresh the agent list afterwards so
  /// the new agent shows up in this app.
  Future<PeerAgentManageResult> createAgent({
    required String peerId,
    required String engine,
    required String cwd,
    String? nodeId,
    String? name,
    String? sessionMode,
    List<String>? additionalDirectories,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return manageAgents(
      peerId: peerId,
      op: 'create',
      nodeId: nodeId,
      engine: engine,
      cwd: cwd,
      name: name,
      sessionMode: sessionMode,
      additionalDirectories: additionalDirectories,
      timeout: timeout,
    );
  }

  void _rememberRecentlyCreatedAgent(String peerId, String remoteAgentId) {
    final key = '${peerId.trim()}::${remoteAgentId.trim()}';
    _recentlyCreatedAgents[key] = DateTime.now();
  }

  void _forgetRecentlyCreatedAgent(String peerId, String? remoteAgentId) {
    final remote = remoteAgentId?.trim() ?? '';
    if (remote.isEmpty) return;
    _recentlyCreatedAgents.remove('${peerId.trim()}::$remote');
  }

  bool _isRecentlyCreatedAgent(String peerId, String? remoteAgentId) {
    final remote = remoteAgentId?.trim() ?? '';
    if (remote.isEmpty) return false;
    final key = '${peerId.trim()}::$remote';
    final createdAt = _recentlyCreatedAgents[key];
    if (createdAt == null) return false;
    if (DateTime.now().difference(createdAt) <= _recentlyCreatedAgentTtl) {
      return true;
    }
    _recentlyCreatedAgents.remove(key);
    return false;
  }

  /// 在主机或工作节点创建实例成功后，先把本机 [RemoteAgent] 行落库，
  /// 让调用方不必阻塞等待下一轮 `agent_list_resp` 才能打开聊天页。
  ///
  /// 同时把 `(peerId, remoteAgentId)` 记入短期保护表：工作节点创建实例时，
  /// `agent_manage_resp` 比 `worker.agents` 名册帧更快回到本机，中间若夹着
  /// 一轮旧的 `agent_list_resp`，[_removeStalePeerAgents] 不会把刚建好的行删掉。
  Future<RemoteAgent> seedCreatedLocalAgent({
    required String peerId,
    required String remoteAgentId,
    required String engine,
    required String cwd,
    String? peerName,
    String? engineDisplayName,
    String? name,
    String? nodeId,
    String? nodeName,
    List<String> additionalDirectories = const [],
    List<PeerAgentManageEntry> manageEntries = const [],
  }) async {
    final remoteId = remoteAgentId.trim();
    _rememberRecentlyCreatedAgent(peerId, remoteId);
    final localId = peerAgentLocalId(peerId, remoteId);
    final hasDb = getIt.isRegistered<LocalDatabaseService>();
    if (hasDb) {
      final existing = await _db.getRemoteAgentById(localId);
      if (existing != null) {
        ChatService().markFreshLocalChannel(
          ChatService().generateChannelId(LocalUserIdentity.id, localId),
        );
        return existing;
      }
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final resolvedPeerName = (peerName != null && peerName.trim().isNotEmpty)
        ? peerName.trim()
        : (hasDb ? await _peerDisplayName(peerId) : '配对设备');
    final entry = manageEntries.where((e) => e.id == remoteId).firstOrNull;
    final trimmedName = name?.trim() ?? '';
    final entryName = entry?.name.trim() ?? '';
    final resolvedName = trimmedName.isNotEmpty
        ? trimmedName
        : (entryName.isNotEmpty
            ? entryName
            : (engineDisplayName?.trim().isNotEmpty == true
                ? engineDisplayName!.trim()
                : engine));
    final trimmedEngine =
        engine.trim().isNotEmpty ? engine.trim() : (entry?.engine.trim() ?? '');
    final trimmedCwd =
        cwd.trim().isNotEmpty ? cwd.trim() : (entry?.cwd.trim() ?? '');
    final trimmedNodeId = nodeId?.trim().toLowerCase();

    final metadata = <String, dynamic>{
      'source_peer_id': peerId,
      'source_peer_name': resolvedPeerName,
      'remote_agent_id': remoteId,
      if (trimmedNodeId != null && trimmedNodeId.isNotEmpty) ...{
        'node_id': trimmedNodeId,
        'node_role': 'worker',
        if (nodeName != null && nodeName.trim().isNotEmpty)
          'node_name': nodeName.trim(),
        'node_online': true,
      } else ...{
        'node_role': 'host',
        'node_online': true,
      },
      if (trimmedEngine.isNotEmpty) 'engine': trimmedEngine,
      'manageable': true,
      'enabled': true,
      'running': true,
      if (trimmedCwd.isNotEmpty) 'cwd': trimmedCwd,
      'additional_directories': additionalDirectories,
    };

    final agent = RemoteAgent(
      id: localId,
      name: resolvedName,
      avatar: defaultAvatarForEngine(trimmedEngine),
      bio: (engineDisplayName != null && engineDisplayName.trim().isNotEmpty)
          ? engineDisplayName.trim()
          : (trimmedEngine.isNotEmpty ? trimmedEngine : null),
      token: '',
      endpoint: 'peer://$peerId/$remoteId',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      status: AgentStatus.online,
      connectedAt: now,
      capabilities: const ['chat'],
      metadata: metadata,
      createdAt: now,
      updatedAt: now,
    );

    if (hasDb) {
      await _db.createRemoteAgent(agent);
      ChatService().markFreshLocalChannel(
        ChatService().generateChannelId(LocalUserIdentity.id, localId),
      );
      PeerConnectionManager.instance.notifyPeerListChanged();
    }
    return agent;
  }

  Future<PeerAgentManageResult> removeAgent({
    required String peerId,
    required String remoteAgentId,
  }) async {
    final result = await manageAgents(
      peerId: peerId,
      op: 'remove',
      agentId: remoteAgentId,
    );
    if (!result.ok) return result;
    // 主机已经删掉实例。先清本机行，会话列表不必等下一轮 agent_list 或重启。
    await _deleteLocalPeerAgent(peerId: peerId, remoteAgentId: remoteAgentId);
    PeerConnectionManager.instance.notifyPeerListChanged();
    return result;
  }

  Future<void> _deleteLocalPeerAgent({
    required String peerId,
    required String remoteAgentId,
  }) async {
    final remote = remoteAgentId.trim();
    if (remote.isEmpty) return;
    final agents = await _db.getAllRemoteAgents();
    for (final agent in agents) {
      if (agent.protocol != ProtocolType.peer || agent.sourcePeerId != peerId) {
        continue;
      }
      if (agent.remoteAgentId != remote) continue;
      await _db.deleteRemoteAgent(agent.id);
      unawaited(SheAgentImpressionService.instance.removeImpression(agent.id));
    }
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
    String? nodeId,
    Duration timeout = const Duration(seconds: 8),
    bool waitForReconnect = true,
  }) async {
    try {
      return await sendWithReloginRetry(
        retryOnRelogin: true,
        reloginGeneration: () => PouchLoginKeeper.instance.reloginGeneration,
        waitForRelogin: (seen) =>
            PouchLoginKeeper.instance.waitForRelogin(seenGeneration: seen),
        send: () => _browseRemoteFsOnce(
          peerId: peerId,
          path: path,
          nodeId: nodeId,
          timeout: timeout,
          waitForReconnect: waitForReconnect,
        ),
      );
    } on PouchLoginRequired {
      return const PeerFsBrowseResult(
        ok: false,
        error: 'login_required',
        code: 'login_required',
      );
    } on Exception {
      return const PeerFsBrowseResult(
        ok: false,
        error: 'timeout',
        unsupported: true,
      );
    }
  }

  Future<PeerFsBrowseResult> _browseRemoteFsOnce({
    required String peerId,
    String? path,
    String? nodeId,
    required Duration timeout,
    required bool waitForReconnect,
  }) async {
    if (!waitForReconnect && !_peerIsConnected(peerId)) {
      return const PeerFsBrowseResult(ok: false, error: 'offline');
    }
    final requestId = _uuid.v4();
    final completer = Completer<PeerFsBrowseResult>();
    _pendingFsBrowse[requestId] = completer;
    final payload = <String, dynamic>{
      'type': 'fs_browse_req',
      'request_id': requestId,
      if (path != null) 'path': path,
      if (nodeId != null) 'node_id': nodeId,
    };
    final sent = await _sendInteractiveControl(
      peerId,
      payload,
      waitForReconnect: waitForReconnect,
    );
    if (!sent) {
      _pendingFsBrowse.remove(requestId);
      return const PeerFsBrowseResult(ok: false, error: 'offline');
    }
    final result = await completer.future.timeout(timeout, onTimeout: () {
      _pendingFsBrowse.remove(requestId);
      return const PeerFsBrowseResult(
        ok: false,
        error: 'timeout',
        unsupported: true,
      );
    });
    if (result.code == 'login_required') {
      throw const PouchLoginRequired();
    }
    return result;
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
        code: data['code'] as String?,
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
      code: data['code'] as String?,
    ));
  }

  void _onEngineStatusResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final completer = _pendingEngineStatus.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    final engines = <PeerEngineEntry>[
      for (final item in (data['engines'] as List?) ?? const [])
        if (item is Map)
          PeerEngineEntry.fromJson(Map<String, dynamic>.from(item)),
    ];
    final error = data['error'] as String?;
    completer.complete(PeerEngineStatusResult(
      ok: data['ok'] == true,
      error: error,
      unsupported: error == 'unsupported',
      code: data['code'] as String?,
      engines: engines,
      summary: PeerEngineStatusSummary.fromJson(data, engines),
      scannedAt: (data['scanned_at'] as num?)?.toInt() ?? 0,
    ));
  }

  void _onEngineControlResp(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final completer = _pendingEngineControl.remove(requestId);
    if (completer == null || completer.isCompleted) return;
    final error = data['error'] as String?;
    completer.complete(PeerEngineControlResult(
      ok: data['ok'] == true,
      error: error,
      code: data['code'] as String?,
      unsupported: data['code'] == 'unsupported' || error == 'unsupported',
      killed: (data['killed'] as num?)?.toInt() ?? 0,
      dropped: (data['dropped'] as num?)?.toInt() ?? 0,
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
    int? readCount;
    final rawReadCount = data['read_count'];
    if (rawReadCount is num) readCount = rawReadCount.toInt();
    DateTime? readAt;
    final rawReadAt = data['read_at'];
    if (rawReadAt is String && rawReadAt.isNotEmpty) {
      readAt = DateTime.tryParse(rawReadAt);
    } else if (rawReadAt is num) {
      final ms = rawReadAt.toInt();
      if (ms > 0) {
        readAt = DateTime.fromMillisecondsSinceEpoch(
          ms < 1000000000000 ? ms * 1000 : ms,
          isUtc: true,
        );
      }
    }
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
      readOnly: data['read_only'] == true,
      archived: data['archived'] == true,
      readCount: readCount,
      readAt: readAt,
    );
    final completer = _pendingHistory.remove('$remoteId::$sessionId');
    if (completer != null && !completer.isCompleted) completer.complete(page);
  }

  /// Fetch an agent's known sessions from the hub (agent.sessions.list relay).
  ///
  /// `null` 是没问到（发送失败、超时、帧里缺 `sessions` 或有条目解析不了）。
  /// 空列表是主机确认这名下没有会话，可以拿来把本机多出来的行清掉。两者不能
  /// 混，否则一次坏帧会把列表删光。
  Future<List<PeerRemoteSession>?> fetchSessions({
    required String peerId,
    required String remoteAgentId,
  }) {
    // 并发调用共用同一次请求；每个调用方各自守着超时，谁先放弃都不会让
    // 后来的人无限等待一个已经被移除的 completer。
    final pending = _pendingSessions[remoteAgentId];
    if (pending != null) {
      return pending.future.timeout(
        _sessionFetchTimeout,
        onTimeout: () => null,
      );
    }
    final completer = Completer<List<PeerRemoteSession>?>();
    _pendingSessions[remoteAgentId] = completer;
    return _requestSessions(peerId, remoteAgentId, completer);
  }

  static const _sessionFetchTimeout = Duration(seconds: 10);

  Future<List<PeerRemoteSession>?> _requestSessions(
    String peerId,
    String remoteAgentId,
    Completer<List<PeerRemoteSession>?> completer,
  ) async {
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_sessions_req',
      'agent_id': remoteAgentId,
    });
    if (!sent) {
      if (identical(_pendingSessions[remoteAgentId], completer)) {
        _pendingSessions.remove(remoteAgentId);
      }
      return null;
    }
    return completer.future.timeout(_sessionFetchTimeout, onTimeout: () {
      if (identical(_pendingSessions[remoteAgentId], completer)) {
        _pendingSessions.remove(remoteAgentId);
      }
      return null;
    });
  }

  void _onSessionsResp(String peerId, Map<String, dynamic> data) {
    final remoteId = data['agent_id'] as String?;
    if (remoteId == null) return;
    final hostNow = data['now_ms'];
    if (hostNow is int && hostNow > 0) {
      _hostNowMs[peerId] = hostNow;
    }
    final completer = _pendingSessions.remove(remoteId);
    if (completer == null || completer.isCompleted) return;
    // 缺字段 / 协议漂移：没问到，不是「主机确认没有」。
    completer.complete(parsePeerSessionList(data['sessions']));
  }

  /// 单帧向主机拉取所有 Agent 的会话摘要与已读水位快照。
  Future<Map<String, List<PeerRemoteSession>>?> fetchSessionsDigest({
    required String peerId,
  }) async {
    final pending = _pendingSessionsDigest[peerId];
    if (pending != null) {
      return pending.future.timeout(
        _sessionsDigestTimeout,
        onTimeout: () => null,
      );
    }
    final completer = Completer<Map<String, List<PeerRemoteSession>>?>();
    _pendingSessionsDigest[peerId] = completer;
    final sent = await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'agent_sessions_digest_req',
      'request_id': _uuid.v4(),
    });
    if (!sent) {
      _pendingSessionsDigest.remove(peerId);
      return null;
    }
    return completer.future.timeout(_sessionsDigestTimeout, onTimeout: () {
      _pendingSessionsDigest.remove(peerId);
      return null;
    });
  }

  static const _sessionsDigestTimeout = Duration(seconds: 6);

  void _onSessionsDigestResp(String peerId, Map<String, dynamic> data) {
    final completer = _pendingSessionsDigest.remove(peerId);
    if (completer == null || completer.isCompleted) return;
    final rawDigests = data['digests'];
    if (rawDigests is! Map) {
      completer.complete(null);
      return;
    }
    final out = <String, List<PeerRemoteSession>>{};
    for (final entry in rawDigests.entries) {
      // 任一条目读不懂就整份快照判为「没问到」，交给逐 Agent 的 fetchSessions
      // 兜底。半份名单拿去剪枝会误删本地会话。
      final key = entry.key;
      final parsed = key is String ? parsePeerSessionList(entry.value) : null;
      if (key is! String || parsed == null) {
        completer.complete(null);
        return;
      }
      out[key] = parsed;
    }
    completer.complete(out);
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
  ///
  /// [includeClientSessions] 为 false 时不新建这个 agent 自己的官方终端 / IDE 会话。
  /// 已经在本地的那些只补上来源标签，不再当成本轮新链入。
  ///
  /// [pruneToHost] 为 true 时，本机多出来的私聊（主机名单里没有的）删掉。
  /// 只在主机确认过这份名单之后打开，超时得到的空列表不能用来删。
  ///
  /// [preserveClientSessions] 为 true 时不剪官方终端 / IDE 会话：主机关掉
  /// 「同步客户端会话」后名单本来就不含它们，不代表主机上删了。
  Future<int> syncSessions({
    required String peerId,
    required String remoteAgentId,
    required String localAgentId,
    required String userId,
    required List<PeerRemoteSession> sessions,
    bool includeClientSessions = true,
    bool pruneToHost = false,
    bool preserveClientSessions = false,
  }) async {
    if (sessions.isEmpty) {
      if (pruneToHost) {
        await _dropPeerChannelsMissingFromHost(
          localAgentId: localAgentId,
          hostSessionIds: const {},
          preserveClientSessions: preserveClientSessions,
        );
      }
      return 0;
    }
    final engine = await _localAgentEngine(localAgentId);
    String? storedOrigin(PeerRemoteSession session) => clientSessionStoreOrigin(
          engine: engine,
          source: session.source,
        );
    var linked = 0;
    for (final s in sessions) {
      if (s.isClientSession && !includeClientSessions) {
        await _stampClientOriginIfPresent(s, storedOrigin(s));
        continue;
      }
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
          sessionOrigin: storedOrigin(s),
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
        final origin = storedOrigin(s);
        if (origin != null && existing.sessionOrigin != origin) {
          await _db.setChannelSessionOrigin(channelId, origin);
        }
      }
      // 列表顺序跟主机的活跃时间走。本机「刚打开过」不再改这个时间，
      // 否则两台客户端会按各自的浏览记录排成两份列表。
      if (s.updatedAt != null) {
        await _db.setChannelUpdatedAt(channelId, s.updatedAt!);
      }
      if (s.readAt != null) {
        await _db.upsertChannelReadWatermark(
          channelId,
          agentId: localAgentId,
          remoteSessionId: s.sessionId,
          readAtMs: s.readAt!.millisecondsSinceEpoch,
          readCount: s.readCount,
          messageCount: s.messageCount,
        );
      }
      if (s.isRead || s.readOnly) {
        await _db.markChannelMessagesAsRead(channelId, syncToHost: false);
      } else if (s.readAt != null) {
        await _db.markChannelMessagesAsReadBefore(
          channelId,
          s.readAt!,
          readCount: s.readCount,
          messageCount: s.messageCount,
          syncToHost: false,
        );
      }
    }
    final considered = sessionsMirroredForHistory(
      sessions,
      includeClientSessions: includeClientSessions,
    );
    if (considered.isNotEmpty &&
        considered.every((s) => s.isRead || s.readOnly)) {
      DateTime? maxReadAt;
      for (final s in considered) {
        final at = s.readAt ?? s.updatedAt;
        if (at != null && (maxReadAt == null || at.isAfter(maxReadAt))) {
          maxReadAt = at;
        }
      }
      await _db.markAllAgentChannelsAsRead(
        localAgentId,
        beforeOrAt: maxReadAt,
        syncToHost: false,
      );
    }
    if (pruneToHost) {
      await _dropPeerChannelsMissingFromHost(
        localAgentId: localAgentId,
        hostSessionIds: sessions.map((s) => s.sessionId).toSet(),
        preserveClientSessions: preserveClientSessions,
      );
    }
    _log.info(
      'Synced $linked/${sessions.length} remote session(s) for peer agent $localAgentId',
      tag: _tag,
    );
    _db.notifyChannelActivity();
    return linked;
  }

  /// 删掉这个 agent 下主机名单里没有的私聊，留下群绑定、She 中转、未发送的
  /// 新会话，以及正在使用 / 有回合在跑 / 刚登记到主机的会话。
  ///
  /// 名单快照可能在用户新建、打开会话之前就取好了，旧快照不能判这些会话
  /// 「主机没有」。
  Future<void> _dropPeerChannelsMissingFromHost({
    required String localAgentId,
    required Set<String> hostSessionIds,
    bool preserveClientSessions = false,
  }) async {
    final local = await _db.getChannelsForAgent(localAgentId);
    final chat = ChatService();
    final fresh = <String>{};
    final protected = <String>{..._recentlyOpenedChannelIds()};
    final activeChannelId = AppLifecycleService().activeChannelId;
    if (activeChannelId != null && activeChannelId.isNotEmpty) {
      protected.add(activeChannelId);
    }
    for (final channel in local) {
      if (chat.isFreshLocalChannel(channel.id)) fresh.add(channel.id);
      if (chat.getActiveTask(channel.id) != null) protected.add(channel.id);
    }
    final drop = peerChannelIdsAbsentFromHost(
      local: local,
      hostSessionIds: hostSessionIds,
      freshChannelIds: fresh,
      protectedChannelIds: protected,
      preserveClientSessions: preserveClientSessions,
    );
    if (drop.isEmpty) return;
    for (final id in drop) {
      await _db.deleteChannelMessages(id);
      await _db.deleteChannel(id);
    }
    _log.info(
      'Dropped ${drop.length} local session(s) not on the host for $localAgentId',
      tag: _tag,
    );
    _db.notifyChannelActivity();
  }

  /// 这个 agent 的引擎 id。官方终端 / IDE 会话的标签用它，不拿别家的名字。
  Future<String?> _localAgentEngine(String localAgentId) async {
    final agent = await _db.getRemoteAgentById(localAgentId);
    final engine = agent?.metadata['engine'];
    if (engine is! String) return null;
    final id = engine.trim();
    return id.isEmpty ? null : id;
  }

  /// 本地已有的官方终端 / IDE 会话补上来源，不新建频道。
  Future<void> _stampClientOriginIfPresent(
    PeerRemoteSession session,
    String? origin,
  ) async {
    if (origin == null) return;
    final channelId = await _localChannelIdForRemoteSession(session.sessionId);
    final existing = await _db.getChannelById(channelId);
    if (existing == null || existing.sessionOrigin == origin) return;
    await _db.setChannelSessionOrigin(channelId, origin);
  }

  final _syncingReadStatePeers = <String>{};

  /// 后台轻量同步该主机下所有远端 Agent 的会话摘要与已读水位（不拉聊天正文），
  /// 优先走单帧 `agent_sessions_digest_req` 快照，一次往返对齐全部 Agent。
  Future<void> syncAllPeerAgentsReadState(String peerId) async {
    final id = peerId.trim();
    if (id.isEmpty || !_peerIsConnected(id)) return;
    if (!_syncingReadStatePeers.add(id)) return;
    try {
      final agents = await _db.getAllRemoteAgents();
      final peerAgents = [
        for (final agent in agents)
          if (agent.metadata['source_peer_id'] == id) agent,
      ];
      if (peerAgents.isEmpty) return;

      final digestMap = await fetchSessionsDigest(peerId: id);
      if (digestMap != null) {
        for (final agent in peerAgents) {
          final remoteId =
              (agent.metadata['remote_agent_id'] as String?)?.trim() ?? '';
          if (remoteId.isEmpty) continue;
          final sessions = digestMap[remoteId];
          // 键不在快照里就别清：那是「没问到」，不是「主机确认没有」。
          if (sessions != null) {
            final clientSyncEnabled = await isClientSessionSyncEnabled(
              agent.id,
              remoteAgentId: remoteId,
            );
            await syncSessions(
              peerId: id,
              remoteAgentId: remoteId,
              localAgentId: agent.id,
              userId: 'user',
              sessions: sessions,
              pruneToHost: true,
              preserveClientSessions: !clientSyncEnabled,
            );
          }
        }
        return;
      }

      for (final agent in peerAgents) {
        final remoteId =
            (agent.metadata['remote_agent_id'] as String?)?.trim() ?? '';
        if (remoteId.isEmpty) continue;
        final sessions = await fetchSessions(
          peerId: id,
          remoteAgentId: remoteId,
        );
        if (sessions != null) {
          final clientSyncEnabled = await isClientSessionSyncEnabled(
            agent.id,
            remoteAgentId: remoteId,
          );
          await syncSessions(
            peerId: id,
            remoteAgentId: remoteId,
            localAgentId: agent.id,
            userId: 'user',
            sessions: sessions,
            pruneToHost: true,
            preserveClientSessions: !clientSyncEnabled,
          );
        }
      }
    } catch (e) {
      _log.debug('syncAllPeerAgentsReadState skipped: $e', tag: _tag);
    } finally {
      _syncingReadStatePeers.remove(id);
    }
  }

  /// 为 `HubEventClient` 收到普通 Agent 会话（`AgentSessionStore`）实时广播的
  /// `message.created` 准备本地会话壳与发送方本地 ID，使对话列表实时更新。
  Future<({String channelId, String senderId, String senderName})>
      prepareLocalTargetForHubMessage({
    required String peerId,
    required String remoteAgentId,
    required String sessionId,
    required String rawChannelId,
    required String senderType,
    required String fallbackSenderId,
    required String fallbackSenderName,
    String? sessionTitle,
  }) async {
    final rAgent = remoteAgentId.trim();
    final rSession = sessionId.trim();
    if (rAgent.isEmpty || rSession.isEmpty) {
      return (
        channelId: rawChannelId,
        senderId: fallbackSenderId,
        senderName: fallbackSenderName,
      );
    }
    try {
      final agents = await _db.getAllRemoteAgents();
      RemoteAgent? matched;
      for (final a in agents) {
        if (a.metadata['remote_agent_id'] == rAgent &&
            a.metadata['source_peer_id'] == peerId) {
          matched = a;
          break;
        }
      }
      matched ??= agents.cast<RemoteAgent?>().firstWhere(
            (a) =>
                a != null &&
                (a.id == rAgent || a.metadata['remote_agent_id'] == rAgent),
            orElse: () => null,
          );
      final localAgentId = matched?.id ?? rAgent;
      final agentName = matched?.name ?? fallbackSenderName;
      final channelId = await _localChannelIdForRemoteSession(rSession);
      final existing = await _db.getChannelById(channelId);
      final name =
          SessionUtils.cleanClaudeSessionTitle(sessionTitle) ?? 'Session';
      if (existing == null) {
        final channel = Channel.withMemberIds(
          id: channelId,
          name: name,
          type: 'dm',
          memberIds: ['user', localAgentId],
          isPrivate: true,
        );
        await _db.createChannel(channel, 'user');
      } else {
        final members = await _db.getChannelMemberIds(channelId);
        if (!members.contains('user')) {
          await _db.addChannelMember(channelId, 'user');
        }
        if (!members.contains(localAgentId)) {
          await _db.addChannelMember(channelId, localAgentId);
        }
      }
      return (
        channelId: channelId,
        senderId: senderType == 'user' ? 'user' : localAgentId,
        senderName: senderType == 'user' ? '' : agentName,
      );
    } catch (_) {
      return (
        channelId: rawChannelId,
        senderId: fallbackSenderId,
        senderName: fallbackSenderName,
      );
    }
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

  /// 主机事件日志被裁掉一截之后调用。
  ///
  /// 事件补不回来的那些消息还在主机的会话记录里，但本地记着「已经同步到
  /// 某时刻」，增量同步不会再去看它们。所以把水位和会话游标一并作废，下次
  /// 打开会话时从头重建，把缺的那段补回来。
  Future<void> invalidateHistorySync() async {
    await _db.clearAllPeerHistoryCursors();
    final prefs = await SharedPreferences.getInstance();
    final stale = prefs.getKeys().where(
          (key) =>
              key.startsWith(peerHistoryLastSyncPrefsPrefix) ||
              key.startsWith(peerHistoryUnstampedPrefsPrefix),
        );
    for (final key in stale.toList()) {
      await prefs.remove(key);
    }
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
  /// 1. Open the current channel before any other session. Local messages are
  ///    already on screen; if the channel is empty, its history is pulled to
  ///    completion and [onPrioritizedChannelDone] runs before the session list.
  ///    Entering an agent shows this session without waiting for the others.
  /// 2. Enumerate remote sessions and ensure local channel shells exist.
  /// 3. Select dirty sessions via [selectDirtySessions] (watermark + overlap).
  /// 4. Pull history for each remaining dirty session.
  /// 5. Advance the watermark to [syncStartedAt] only if every attempt finishes
  ///    without throwing.
  ///
  /// [onPrioritizedChannelDone] may run more than once: after the first page
  /// (so the chat opens) and again when that channel's history is fully
  /// mirrored (so the latest window replaces the oldest page). `written == 0`
  /// means the channel was already readable and the UI should drop its wait.
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
    String? earlyRemoteId;
    // 当前会话已在枚举其他会话之前拉完。null 表示没有提前拉。
    int? prefetchedWritten;
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
      if ((count > 0 || ChatService().isFreshLocalChannel(openChannelId)) &&
          onPrioritizedChannelDone != null) {
        // 本地已有这份聊天记录，或这是本机刚建、主机一定还没有正文的空会话。
        // 先撤掉进页等待，再去同步其他会话。
        prioritizedDone = true;
        await onPrioritizedChannelDone(0);
        await Future<void>.delayed(Duration.zero);
      } else if (resolved == openChannelId &&
          peerHistoryShouldPrefetchOpenChannel(
            localMessageCount: count,
            hasCursorRow: stored != null,
          )) {
        earlyRemoteId = remoteId;
        try {
          prefetchedWritten = await syncHistory(
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
        } catch (e, st) {
          _log.warning(
            'Open-channel history prefetch failed for $localAgentId: $e\n$st',
            tag: _tag,
            error: e,
          );
          prefetchedWritten = -1;
        }
        final shown = prefetchedWritten;
        if (shown > 0 && onPrioritizedChannelDone != null) {
          // 第一页是最旧的一页。整段拉完再刷新一次，打开的才是最近的记录。
          prioritizedDone = true;
          await onPrioritizedChannelDone(shown);
        } else if (!prioritizedDone && onPrioritizedChannelDone != null) {
          prioritizedDone = true;
          await onPrioritizedChannelDone(0);
        }
        await Future<void>.delayed(Duration.zero);
      }
    }
    final remoteSessions = await fetchSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
    );
    if (remoteSessions == null) {
      final prefetched = prefetchedWritten ?? 0;
      if (prefetched > 0) {
        return PeerAgentIncrementalSyncResult(
          currentChannelMessagesWritten: prefetched,
        );
      }
      return const PeerAgentIncrementalSyncResult();
    }
    final clientSyncEnabled = await isClientSessionSyncEnabled(
      localAgentId,
      remoteAgentId: remoteAgentId,
    );
    if (remoteSessions.isEmpty) {
      await syncSessions(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        localAgentId: localAgentId,
        userId: userId,
        sessions: remoteSessions,
        pruneToHost: true,
        preserveClientSessions: !clientSyncEnabled,
      );
      final prefetched = prefetchedWritten ?? 0;
      if (prefetched > 0) {
        return PeerAgentIncrementalSyncResult(
          currentChannelMessagesWritten: prefetched,
        );
      }
      return const PeerAgentIncrementalSyncResult();
    }

    const includeClientSessions = true;
    final linked = await syncSessions(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      localAgentId: localAgentId,
      userId: userId,
      sessions: remoteSessions,
      includeClientSessions: includeClientSessions,
      pruneToHost: true,
      preserveClientSessions: !clientSyncEnabled,
    );
    // 开关本身不在这一层判断：主机关掉时名单里根本不会带官方终端 / IDE
    // 会话。名单里带上来就是本轮该补历史的；开关重新打开后名单恢复，
    // 这些会话照常进入脏会话选择（本地还是空壳的会被优先选中）。
    final sessions = sessionsMirroredForHistory(
      remoteSessions,
      includeClientSessions: includeClientSessions,
    );
    if (sessions.isEmpty) {
      final prefetched = prefetchedWritten ?? 0;
      return PeerAgentIncrementalSyncResult(
        sessionsLinked: linked,
        currentChannelMessagesWritten: prefetched > 0 ? prefetched : 0,
      );
    }

    final lastSyncAt = await getLastHistorySyncAt(localAgentId);
    final syncedUnstamped = await getSyncedUnstampedSessionIds(localAgentId);
    final remoteSessionIds = sessions.map((s) => s.sessionId).toSet();
    final prioritizeSessionId = peerRemoteSessionIdForLocalChannel(
      prioritizeChannelId,
      knownRemoteSessionIds: remoteSessionIds,
    );
    if (!prioritizedDone &&
        prioritizeSessionId == null &&
        onPrioritizedChannelDone != null) {
      // 当前打开的会话不在远端会话名单里（例如本机新建的空单聊），
      // 先释放当前会话的进页同步等待，其余历史会话在后台继续拉取。
      prioritizedDone = true;
      await onPrioritizedChannelDone(0);
      await Future<void>.delayed(Duration.zero);
    }
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

    // 一次增量会往几十个会话各写一条消息。通知攒到循环结束再发，
    // 会话列表和聊天页只刷新一次；打开中的会话仍由
    // onPrioritizedChannelDone 在第一页到达时直接刷新。
    _db.beginActivityBatch();
    try {
      for (final session in dirty) {
        final psessId = syncedPeerChannelId(session.sessionId);
        final legacyId = session.sessionId;
        final channelId = resolveLocalPeerChannelId(
          session.sessionId,
          psessExists: await _db.getChannelById(psessId) != null,
          legacyExists: await _db.getChannelById(legacyId) != null,
        );
        if (earlyRemoteId != null && session.sessionId == earlyRemoteId) {
          final written = prefetchedWritten;
          earlyRemoteId = null;
          prefetchedWritten = null;
          if (written != null && written >= 0) {
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
          } else if (stored > 0 && onPrioritizedChannelDone != null) {
            // 第一页只覆盖最旧的记录。这一会话全部落库后再刷新最近一窗。
            await onPrioritizedChannelDone(stored);
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
    } finally {
      _db.endActivityBatch();
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
    // 水位记在主机的时间轴上：下次判脏是拿它比主机的 `updatedAt`，用本机
    // 时钟记就会受两端偏差影响。主机没给（旧版本）才退回本地时刻。
    final hostNow = _hostNowMs[peerId];
    await setLastHistorySyncAt(
      localAgentId,
      hostNow == null
          ? syncStartedAt
          : DateTime.fromMillisecondsSinceEpoch(hostNow, isUtc: true),
    );
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

  /// 这个会话有没有还没补发出去的 mark_read。
  ///
  /// 有的话远端未读只是上行迟到，不是主机否定了已读，重同步时不能拿它撤销
  /// 本地已读 —— 否则红点会莫名复活，补发成功后再标回去。
  Future<bool> _hasPendingReadFor(String channelId) async {
    final ops = await _db.listPendingOps(kind: 'mark_read');
    if (ops.isEmpty) return false;
    final bare = remoteSessionIdFromChannelId(channelId) ?? channelId;
    final wanted = <String>{channelId, bare, syncedPeerChannelId(bare)};
    for (final op in ops) {
      final target = (op['target_id'] as String? ?? '').trim();
      if (target.isEmpty) continue;
      if (wanted.contains(target)) return true;
      if (wanted.contains(remoteSessionIdFromChannelId(target) ?? target)) {
        return true;
      }
    }
    return false;
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
    final keepLocalRead = await _hasPendingReadFor(channelId);
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
                keepLocalRead: keepLocalRead,
                sessionUpdatedAt: sessionUpdatedAt,
                pageReadOnly: page.readOnly || page.archived,
                pageReadCount: page.readCount,
                pageReadAt: page.readAt,
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
              keepLocalRead: keepLocalRead,
              sessionUpdatedAt: sessionUpdatedAt,
              floorIds: needsCleanup ? seenIds : null,
              pageReadOnly: page.readOnly || page.archived,
              pageReadCount: page.readCount,
              pageReadAt: page.readAt,
            );
      written += pageWritten;
      if (page.readOnly ||
          page.archived ||
          (page.readCount != null &&
              page.total > 0 &&
              page.readCount! >= page.total)) {
        await _db.markChannelMessagesAsRead(channelId, syncToHost: false);
      }
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
    required bool keepLocalRead,
    DateTime? sessionUpdatedAt,
    Set<String>? floorIds,
    bool pageReadOnly = false,
    int? pageReadCount,
    DateTime? pageReadAt,
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

    final localRows = await _db.listNonPeerhistMessages(channelId);
    final localReadRoleContentKeys = <String>{};
    final localReadRequestIds = <String>{};
    for (final row in localRows) {
      if ((row['is_read'] as int? ?? 0) == 0) continue;
      final rowId = row['id'] as String?;
      if (rowId != null && rowId.isNotEmpty) {
        localReadRequestIds.add(rowId);
      }
      final role = (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
      localReadRoleContentKeys.add(
        peerHistoryRoleContentKey(role, row['content'] as String? ?? ''),
      );
      final rawMeta = row['metadata'];
      if (rawMeta is String && rawMeta.isNotEmpty) {
        try {
          final decoded = jsonDecode(rawMeta);
          if (decoded is Map && decoded['request_id'] is String) {
            localReadRequestIds.add(decoded['request_id'] as String);
          }
        } catch (_) {}
      }
    }

    final indexes = peerHistorySliceWriteIndexes(
      history: history,
      from: from,
      channelId: channelId,
      existingById: existingRowsById,
      createdAts: createdAts,
      keepLocalRead: keepLocalRead,
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
      final globalIndex = from + i;
      final createdAt = createdAts[i];
      final forceRead = pageReadOnly ||
          message.role == 'user' ||
          (pageReadCount != null && globalIndex < pageReadCount) ||
          (pageReadAt != null && !createdAt.isAfter(pageReadAt)) ||
          localReadRoleContentKeys.contains(
            peerHistoryRoleContentKey(message.role, message.content),
          ) ||
          (message.messageId != null &&
              localReadRequestIds.contains(message.messageId));
      inserts.add(_historyStoredRow(
        message: message,
        id: msgId,
        channelId: channelId,
        userId: userId,
        userName: userName,
        localAgentId: localAgentId,
        agentName: agentName,
        createdAt: createdAt,
        existingRow: existingRowsById[msgId],
        forceRead: forceRead,
      ));
    }
    await _db.createMessages(inserts);

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
    required bool keepLocalRead,
    DateTime? sessionUpdatedAt,
    bool pageReadOnly = false,
    int? pageReadCount,
    DateTime? pageReadAt,
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
    final localReadRoleContentKeys = <String>{};
    final localReadRequestIds = <String>{};
    for (final row in existingAsc) {
      final id = row['id'] as String?;
      final rawAt = row['created_at'] as String?;
      if (id == null || rawAt == null) continue;
      existingRowsById[id] = row;
      final at = DateTime.tryParse(rawAt);
      if (at != null) existingById[id] = at;
      if (!id.startsWith('peerhist_') && (row['is_read'] as int? ?? 0) != 0) {
        localReadRequestIds.add(id);
        final role =
            (row['sender_type'] as String?) == 'user' ? 'user' : 'agent';
        localReadRoleContentKeys.add(
          peerHistoryRoleContentKey(role, row['content'] as String? ?? ''),
        );
        final rawMeta = row['metadata'];
        if (rawMeta is String && rawMeta.isNotEmpty) {
          try {
            final decoded = jsonDecode(rawMeta);
            if (decoded is Map && decoded['request_id'] is String) {
              localReadRequestIds.add(decoded['request_id'] as String);
            }
          } catch (_) {}
        }
      }
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
      keepLocalRead: keepLocalRead,
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
      final metadata = metadataPreservingProgress(
        incoming: display.metadata,
        existingMetadataJson: existingRow?['metadata'] as String?,
      );
      final createdAt = createdAts[i];
      final forceRead = pageReadOnly ||
          isUser ||
          (pageReadCount != null && i < pageReadCount) ||
          (pageReadAt != null && !createdAt.isAfter(pageReadAt)) ||
          localReadRoleContentKeys.contains(
            peerHistoryRoleContentKey(m.role, m.content),
          ) ||
          localReadRoleContentKeys.contains(
            peerHistoryRoleContentKey(m.role, display.content),
          ) ||
          (m.messageId != null && localReadRequestIds.contains(m.messageId));
      final isRead = forceRead
          ? 1
          : preservedReadStateForHistorySync(
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
          metadata: metadata,
          // ConflictAlgorithm.replace rewrites the whole row, so the reply link
          // has to be carried over explicitly — it is the only causal edge
          // MessageUtils.orderForDisplay can fall back on when stamps are coarse.
          replyToId: peerHistoryReplyToId(m.replyTo) ??
              existingRow?['reply_to_id'] as String?,
          createdAt: createdAt,
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
    bool forceRead = false,
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
      isRead: forceRead
          ? 1
          : preservedReadStateForHistorySync(
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
    ChatService.slashCommandsSnapshotHook?.call(remoteId, commands);
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

  /// AskUserQuestion（ACP `elicitation/create`）被 hub 收成一张表单。
  /// 占用和工具审批同一道闸门，用户填表期间回合不会被空闲超时关掉。
  void _onFormReq(String peerId, Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    final approvalId = data['approval_id'] as String? ?? '';
    if (requestId == null || approvalId.isEmpty) {
      _log.warning('agent_form_req: missing request_id or approval_id',
          tag: 'PeerApproval');
      return;
    }
    final stored = _submittedForms[approvalId];
    if (stored != null) {
      unawaited(PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'agent_form_resp',
        'approval_id': approvalId,
        'action': stored['action'] ?? 'accept',
        if (stored['content'] != null) 'content': stored['content'],
      }));
      return;
    }
    final pending = _pending[requestId];
    if (_approvalToRequest.containsKey(approvalId)) {
      return;
    }
    // hub 会在手机重连后把没答过的卡片补发回来，但那时未必还有能投递的地方：
    // `_pending` 可能已被 resume 重试耗尽清掉，或者 turn 刚从磁盘恢复、UI 还
    // 没重新挂上 onForm。这两种都不能静默丢弃 —— 主机只会按
    // `SHEPAW_ACP_APPROVAL_SECS`（默认 30 分钟）等，过了就自己降级往下跑，
    // 卡片丢了等于用户连「回答的机会」都没有，只能眼看整轮替他做决定。
    if (pending == null || pending.onForm == null) {
      _republishOrphanForm(
        peerId: peerId,
        requestId: requestId,
        approvalId: approvalId,
        data: data,
        hasPendingTurn: pending != null,
        // 卡片是广播过来的、本机没发起过这一轮时，`_requestAgents` 和 `_pending`
        // 都没有记录；帧里的 `agent_id` 就是远端 agent id，靠它把卡路由到会话。
        remoteAgentId: _requestAgents[requestId]?.remoteAgentId ??
            pending?.remoteAgentId ??
            data['agent_id'] as String?,
      );
    }
    if (pending == null) {
      return;
    }
    pending.openApprovals++;
    pending.lastApprovalOpenedAt = DateTime.now();
    _approvalToRequest[approvalId] = requestId;
    // 先落库再交给 UI：卡片只活在流式气泡的内存 metadata 里的话，
    // 聊天页重开/控制器重建/DB reconcile 都会让它消失，而主机还在等。
    if (pending.channelId.isNotEmpty) {
      unawaited(persistFormCard(
        channelId: pending.channelId,
        senderId: pending.localAgentId,
        senderName: pending.agentName,
        formData: {
          'form_id': approvalId,
          'request_id': requestId,
          'title': data['title'] ?? '',
          if (data['description'] != null) 'description': data['description'],
          'fields': data['fields'] is List ? data['fields'] : const <dynamic>[],
          'peer_form': {'peer_id': peerId, 'approval_id': approvalId},
        },
      ));
    }
    final fields = data['fields'];
    pending.onForm?.call({
      'form_id': approvalId,
      'request_id': requestId,
      'title': data['title'] ?? '',
      if (data['description'] != null) 'description': data['description'],
      'fields': fields is List ? fields : const <dynamic>[],
      'peer_form': {
        'peer_id': peerId,
        'approval_id': approvalId,
      },
      // 卡片归属的会话；聊天页据此决定要不要画在当前列表里。
      'channel_id': pending.channelId,
    });
  }

  /// 回合内没等到回答：主机把卡片交到 deferred 表，这一轮随后收束。
  ///
  /// 只做记账：卡片不能继续占着旧回合的审批额度（否则随后的 `agent_done`
  /// 会被 [_onDone] 无限缓冲），也不能被旧回合的收尾路径收掉。作答时由
  /// [submitForm] 走 App 自己的新回合。
  Future<void> _onFormDeferred(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final approvalId = data['approval_id'] as String? ?? '';
    if (approvalId.isEmpty) {
      _log.warning('agent_form_deferred: missing approval_id',
          tag: 'PeerApproval');
      return;
    }
    // 补发的帧可能晚于本机已经提交的答案：别再把它放回可答状态，
    // 否则会重复开一轮。
    if (_submittedForms.containsKey(approvalId)) {
      _log.info(
        'agent_form_deferred: approvalId=$approvalId already submitted — ignore',
        tag: 'PeerApproval',
      );
      return;
    }
    final pending = _pending[requestId];
    if (pending != null && pending.openApprovals > 0) {
      pending.openApprovals--;
      if (pending.openApprovals == 0) pending.idleSince = DateTime.now();
    }
    final knownInline = _approvalToRequest.remove(approvalId) != null;
    _orphanedApprovals.remove(approvalId);
    final orphan = _orphanedForms.remove(approvalId);
    _deferredForms[approvalId] = requestId;
    if (_deferredForms.length > 50) {
      _deferredForms.remove(_deferredForms.keys.first);
    }
    _log.info(
      'agent_form_deferred: approvalId=$approvalId requestId=$requestId',
      tag: 'PeerApproval',
    );
    if (orphan != null) {
      // 卡片本地有留底但还没投出去：把 deferred 一起记下，聊天页后开时
      // 仍按「回合外等待」渲染。
      _orphanedForms[approvalId] = Map<String, dynamic>.from(orphan)
        ..['deferred'] = true;
    } else if (!knownInline) {
      // 重连补发 / 另一台设备第一次看到这张卡：本地没有卡，走孤儿表单
      // 投出去。只记账不渲染的话，这张卡在这些设备上等于不存在。
      _republishOrphanForm(
        peerId: peerId,
        requestId: requestId,
        approvalId: approvalId,
        data: {...data, 'deferred': true},
        hasPendingTurn: pending != null,
        remoteAgentId: _requestAgents[requestId]?.remoteAgentId ??
            pending?.remoteAgentId ??
            data['agent_id'] as String?,
      );
    }
    // 先把 deferred 写进卡片行，再结束回合并通知 UI：回合结束可能触发
    // loadMessages，晚到的写入会被数据库里的旧快照盖掉。
    await _persistFormDeferred(approvalId, requestId, peerId);
    _tryCompleteBufferedDone(requestId);
    if (!_formDeferredController.isClosed) {
      _formDeferredController
          .add((approvalId: approvalId, requestId: requestId));
    }
    // 独立卡片一出现就表示旧回合已经结束：不能继续挂着等用户回答。主机还要
    // 等引擎吃完 session/cancel（最多 cancel_grace），真正的 agent_done 会晚
    // 几秒才到；这里立刻按 deferred 收掉本轮。那一帧随后到达时 `_pending`
    // 已经摘掉，会被 [_onDone] 忽略。
    _onDone({
      'request_id': requestId,
      'content': '',
      'deferred': true,
      'end_reason': 'deferred',
    });
  }

  /// 把 `deferred: true` 写进卡片行。乱序时旧回合的 `turn_ended` 可能已经
  /// 写了 `closed`，这里把它清掉 —— 这张卡并没有作废，它在等用户以后点。
  Future<void> _persistFormDeferred(
    String approvalId,
    String requestId,
    String peerId,
  ) async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    try {
      final row = await _db.getMessageById(
        PeerApprovalPayload.formCardMessageId(approvalId),
      );
      if (row == null) {
        // 这张卡不在本机发起过的那条流里（别的设备问的、或本地还没落行）：
        // 没有可更新的行，等下次补发时按 deferred 帧正常渲染。
        return;
      }
      await _writeClosedMetadata(
        row,
        (metadata) => metadataMarkingFormDeferred(
          metadata,
          interactionId: approvalId,
        ),
      );
    } catch (e) {
      _log.warning(
        'persist form deferred failed: approvalId=$approvalId '
        'requestId=$requestId peerId=$peerId $e',
        tag: 'PeerApproval',
        error: e,
      );
    }
  }

  /// 恢复在途回合时收到的表单。
  ///
  /// 恢复路径没有 `sendChat` 的 `onForm` 回调，卡片也不能再贴回流式气泡
  /// （重开页面会从 SQLite 再载出一条确定性卡片行）。按孤儿卡投给聊天页，
  /// 最终落到同一条 `peer_form_<approval_id>` 消息上。
  void surfaceRestoredForm(Map<String, dynamic> data) {
    final form = Map<String, dynamic>.from(data);
    final peerForm = form['peer_form'];
    final rawFormId = form['form_id']?.toString() ?? '';
    final approvalId = rawFormId.isNotEmpty
        ? rawFormId
        : (peerForm is Map ? peerForm['approval_id']?.toString() ?? '' : '');
    final requestId = form['request_id']?.toString() ?? '';
    final peerId = peerForm is Map ? peerForm['peer_id']?.toString() ?? '' : '';
    final remoteAgentId =
        _pending[requestId]?.remoteAgentId ?? form['agent_id']?.toString();
    if (approvalId.isEmpty || requestId.isEmpty || peerId.isEmpty) {
      _log.warning(
        'restored form cannot be surfaced: approvalId=$approvalId '
        'requestId=$requestId peerId=$peerId',
        tag: 'PeerApproval',
      );
      return;
    }
    if (remoteAgentId == null) {
      _log.warning(
        'restored form has no owning agent: approvalId=$approvalId '
        'requestId=$requestId',
        tag: 'PeerApproval',
      );
      return;
    }
    _republishOrphanForm(
      peerId: peerId,
      requestId: requestId,
      approvalId: approvalId,
      data: form,
      hasPendingTurn: _pending.containsKey(requestId),
      remoteAgentId: remoteAgentId,
    );
  }

  /// 把一张投递不出去的表单存下来，并交给打开的聊天页渲染。
  /// 幂等：hub 重复补发同一张卡时不再灌一次流，免得清掉用户已填的内容。
  /// 提交走 [submitForm]，它只需要 peer_id + approval_id。
  void _republishOrphanForm({
    required String peerId,
    required String requestId,
    required String approvalId,
    required Map<String, dynamic> data,
    required bool hasPendingTurn,
    required String? remoteAgentId,
  }) {
    if (_orphanedForms.containsKey(approvalId)) {
      _log.info(
        'agent_form_req: duplicate orphan form approvalId=$approvalId — '
        'skip UI refresh',
        tag: 'PeerApproval',
      );
      return;
    }
    _log.warning(
      'agent_form_req: no deliverable onForm for requestId=$requestId '
      '(hasPendingTurn=$hasPendingTurn) — buffering as orphan form '
      'approvalId=$approvalId',
      tag: 'PeerApproval',
    );
    // 路由字段一起留底：聊天页后开时靠它把卡补投给正确的会话。
    _orphanedForms[approvalId] = Map<String, dynamic>.from(data)
      ..['_peer_id'] = peerId
      ..['_remote_agent_id'] = remoteAgentId;
    if (_orphanedForms.length > 50) {
      _orphanedForms.remove(_orphanedForms.keys.first);
    }
    if (remoteAgentId == null) {
      _log.warning(
        'agent_form_req: no owning agent for requestId=$requestId — orphan '
        'form approvalId=$approvalId has nowhere to render',
        tag: 'PeerApproval',
      );
      return;
    }
    unawaited(_publishOrphanCardToHub(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      cardId: approvalId,
      hostChannelId: _frameChannelId(data),
      interactionType: 'form',
      data: data,
    ));
    if (_orphanFormController.isClosed) return;
    _orphanFormController.add(
      _orphanFormEvent(
        peerId: peerId,
        requestId: requestId,
        approvalId: approvalId,
        data: data,
        remoteAgentId: remoteAgentId,
      ),
    );
  }

  /// 缓存里属于某个 peer agent 的孤儿表单。
  ///
  /// [orphanFormEvents] 是广播流：卡片到达时聊天页没开着，事件就丢了。
  /// 聊天页打开后调用这里把当时没投出去的卡补上。给了 [hostChannelId] 时
  /// 只补这个会话的卡 —— 同一 agent 可能有多个会话，不能把别的会话的卡
  /// 贴进当前页面。
  ///
  /// [includeUnattributed] 为 true 时也补旧帧里没有 `channel_id` 的卡：
  /// 它们的提醒只能落到这名 agent 的普通单聊，单聊页面才会认领。
  List<Map<String, dynamic>> pendingOrphanFormsFor({
    required String peerId,
    required String remoteAgentId,
    String? hostChannelId,
    bool includeUnattributed = false,
  }) {
    final events = <Map<String, dynamic>>[];
    for (final entry in _orphanedForms.entries) {
      final data = entry.value;
      if (data['_peer_id'] != peerId) continue;
      if (data['_remote_agent_id'] != remoteAgentId) continue;
      final frameChannel = _frameChannelId(data);
      if (hostChannelId != null &&
          !(includeUnattributed && frameChannel.isEmpty) &&
          frameChannel != hostChannelId) {
        continue;
      }
      events.add(
        _orphanFormEvent(
          peerId: peerId,
          requestId: data['request_id'] as String? ?? '',
          approvalId: entry.key,
          data: data,
          remoteAgentId: remoteAgentId,
        ),
      );
    }
    return events;
  }

  /// 缓存里属于某个 peer agent 的孤儿审批。
  ///
  /// 与 [pendingOrphanFormsFor] 同一个成因：卡片到达时聊天页没开着，
  /// [orphanApprovalEvents] 的广播就丢了。聊天页打开后按会话补投。
  /// [includeUnattributed] 的含义同 [pendingOrphanFormsFor]。
  List<Map<String, dynamic>> pendingOrphanApprovalsFor({
    required String peerId,
    required String remoteAgentId,
    String? hostChannelId,
    bool includeUnattributed = false,
  }) {
    final events = <Map<String, dynamic>>[];
    for (final entry in _orphanedApprovals.entries) {
      final data = entry.value;
      final frameAgent = data['agent_id'] as String?;
      if (frameAgent != null &&
          frameAgent.isNotEmpty &&
          frameAgent != remoteAgentId) {
        continue;
      }
      final frameChannel = _frameChannelId(data);
      if (hostChannelId != null &&
          !(includeUnattributed && frameChannel.isEmpty) &&
          frameChannel != hostChannelId) {
        continue;
      }
      final rawActions = data['actions'];
      final actionData = PeerApprovalPayload.buildActionConfirmationData(
        data: data,
        approvalId: entry.key,
        actions: PeerApprovalPayload.effectiveActions(
          rawActions is List ? rawActions : null,
        ),
      );
      actionData['request_id'] = data['request_id'] as String? ?? '';
      events.add({
        ...actionData,
        'peer_id': peerId,
        'remote_agent_id': remoteAgentId,
        'channel_id': _frameChannelId(data),
        'orphan': true,
      });
    }
    return events;
  }

  String _frameChannelId(Map<String, dynamic> data) =>
      (data['channel_id'] as String?)?.trim() ?? '';

  /// 把一张暂时投不进打开会话的卡登记到全局提醒（顶部横幅 / 列表角标）。
  ///
  /// 卡片归属由帧里的 `channel_id` 决定；这里只负责「横幅能点回那张卡」。
  /// 会话页随后渲染时用同一个 id upsert，会把 `messageId` 合并进去。
  Future<void> _publishOrphanCardToHub({
    required String peerId,
    required String remoteAgentId,
    required String cardId,
    required String hostChannelId,
    required String interactionType,
    required Map<String, dynamic> data,
  }) async {
    if (cardId.isEmpty || remoteAgentId.isEmpty) return;
    // 纯逻辑单测没有注册本地库；提醒只是 UI 兜底，缺了不影响收卡。
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final channelId = await _localChannelIdForCard(
      peerId: peerId,
      remoteAgentId: remoteAgentId,
      hostChannelId: hostChannelId,
    );
    if (channelId == null || channelId.isEmpty) {
      _log.warning(
        'peer card $cardId ($interactionType) has no local channel — '
        'no reminder registered',
        tag: 'PeerApproval',
      );
      return;
    }
    final localAgentId =
        await _localAgentIdForRemote(peerId, remoteAgentId) ?? remoteAgentId;
    final agentName =
        (await _db.getRemoteAgentById(localAgentId))?.name ?? remoteAgentId;
    final item = PendingApprovalItem.fromInteraction(
      channelId: channelId,
      agentId: localAgentId,
      agentName: agentName,
      interactionType: interactionType,
      data: {
        ...data,
        if (interactionType == 'form') 'form_id': data['form_id'] ?? cardId,
        if (interactionType == 'action_confirmation')
          'confirmation_id': data['confirmation_id'] ?? cardId,
      },
    );
    if (item != null) PendingApprovalHub.instance.upsert(item);
  }

  /// 主机会话 id → 本机频道 id。
  ///
  /// 帧里的 `channel_id` 是当初发给主机的 `session_id`：普通单聊就是频道
  /// id，主机自建会话则是去掉 `psess_` 的原值。两个都查一遍；都没镜像时
  /// 指向 `psess_` 壳（同步后就会出现），横幅点开才不会是一条空会话。
  /// 帧里没有归属时退回该 agent 的普通单聊，绝不落到「当前打开的会话」。
  Future<String?> _localChannelIdForCard({
    required String peerId,
    required String remoteAgentId,
    required String hostChannelId,
  }) async {
    if (hostChannelId.isNotEmpty) {
      if (await _db.getChannelById(hostChannelId) != null) {
        return hostChannelId;
      }
      final synced = syncedPeerChannelId(hostChannelId);
      if (await _db.getChannelById(synced) != null) return synced;
      // 还没镜像：同步会为这个会话建 `psess_` 壳，指向那个 id，别用主机
      // 原始 id 占位——那个 id 在本机永远不会有对应的会话行。
      return synced;
    }
    _log.warning(
      'peer card without channel_id (peer=$peerId agent=$remoteAgentId) — '
      'falling back to the agent DM',
      tag: 'PeerApproval',
    );
    final local =
        await _localAgentIdForRemote(peerId, remoteAgentId) ?? remoteAgentId;
    final channels = await _db.getChannelsForAgent(local);
    if (channels.isEmpty) return null;
    for (final channel in channels) {
      if (channel.sourceGroupChannelId == null &&
          channel.sourceSheChannelId == null) {
        return channel.id;
      }
    }
    return channels.first.id;
  }

  Map<String, dynamic> _orphanFormEvent({
    required String peerId,
    required String requestId,
    required String approvalId,
    required Map<String, dynamic> data,
    required String remoteAgentId,
  }) {
    final fields = data['fields'];
    return {
      'form_id': approvalId,
      'request_id': requestId,
      'title': data['title'] ?? '',
      if (data['description'] != null) 'description': data['description'],
      'fields': fields is List ? fields : const <dynamic>[],
      'peer_form': {
        'peer_id': peerId,
        'approval_id': approvalId,
      },
      'peer_id': peerId,
      'remote_agent_id': remoteAgentId,
      // 发起回合的会话；聊天页只认领属于自己频道的卡。
      'channel_id': _frameChannelId(data),
      // 没有活动 turn 撑着这张卡，UI 不该显示提交中的转圈。
      'orphan': true,
      // 回合外等待的卡：留在屏幕上，可作答或明确拒绝。
      if (data['deferred'] == true) 'deferred': true,
    };
  }

  /// 把一张表单卡落成一条确定性 id 的消息行。
  ///
  /// id 由 `approval_id` 派生（[PeerApprovalPayload.formCardMessageId]）：
  /// 重连补发、跨设备广播重投同一张卡时落到同一行，不会在聊天记录里堆出
  /// 好几张一样的表；`ignore` 也保证已经提交/作废的状态不被旧卡盖掉。
  Future<void> persistFormCard({
    required Map<String, dynamic> formData,
    required String channelId,
    required String senderId,
    String senderName = '',
  }) async {
    final approvalId = formData['form_id']?.toString() ?? '';
    if (approvalId.isEmpty || channelId.isEmpty || senderId.isEmpty) return;
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    final peerForm = formData['peer_form'];
    final peerId = peerForm is Map ? peerForm['peer_id']?.toString() ?? '' : '';
    // 路由字段只用来定位会话，别混进卡片数据里（孤儿卡事件会带上）。
    final form = Map<String, dynamic>.from(formData)
      ..remove('peer_id')
      ..remove('remote_agent_id')
      ..remove('channel_id')
      ..remove('orphan');
    form['form_id'] = approvalId;
    if (peerId.isNotEmpty) {
      form['peer_form'] = {'peer_id': peerId, 'approval_id': approvalId};
    }
    try {
      await _db.createMessage(
        id: PeerApprovalPayload.formCardMessageId(approvalId),
        channelId: channelId,
        senderId: senderId,
        senderType: 'agent',
        senderName: senderName.isEmpty ? 'Agent' : senderName,
        content: (form['title'] as String?) ?? '',
        metadata: {
          'form': form,
          'agent_id': senderId,
          if (senderName.isNotEmpty) 'agent_name': senderName,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    } catch (e) {
      _log.warning('persist form card failed: $e',
          tag: 'PeerApproval', error: e);
    }
  }

  /// 把表单答案送回 hub，解开正在等的 `elicitation/create`。
  ///
  /// 返回 `true` 表示这张卡已经是 deferred：主机不会把答案送回旧回合，
  /// 调用方要用卡片内容另发一条消息开新回合。
  Future<bool> submitForm({
    required String peerId,
    required String approvalId,
    required Map<String, dynamic> values,
  }) async {
    var tracked = _approvalToRequest.containsKey(approvalId) ||
        _orphanedApprovals.containsKey(approvalId) ||
        _orphanedForms.containsKey(approvalId) ||
        _deferredForms.containsKey(approvalId);
    // 进程重启后卡片是从 SQLite 的确定性行渲染出来的，内存账簿是空的。
    // 主机重连补发这张卡之前用户就点了提交，不该被判成「不认识这张卡」。
    tracked = tracked || await _isPersistedOpenForm(approvalId);
    if (!tracked) {
      throw const PeerApprovalExpiredException();
    }
    final payload = <String, dynamic>{
      'type': 'agent_form_resp',
      'approval_id': approvalId,
      'action': 'accept',
      'content': values,
    };
    var sent = false;
    Object? lastErr;
    final sendControl =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        sent = await sendControl(peerId, payload)
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
        'submitForm FAILED approvalId=$approvalId err=$lastErr',
        tag: 'PeerApproval',
      );
      throw Exception('表单发送失败，请确认配对设备在线后重试');
    }
    final requestId = _approvalToRequest.remove(approvalId);
    // 这张卡是回合外作答：主机已经不在旧通道等它了。
    final wasDeferred = _deferredForms.remove(approvalId) != null;
    // 孤儿表单提交成功后清掉占位，避免重复点击落到 NO MATCH。
    _orphanedForms.remove(approvalId);
    _submittedForms[approvalId] = {
      'action': 'accept',
      'content': values,
    };
    unawaited(_persistFormSubmitted(approvalId, values));
    if (_submittedForms.length > 50) {
      _submittedForms.remove(_submittedForms.keys.first);
    }
    if (requestId != null) {
      final pending = _pending[requestId];
      if (pending != null && pending.openApprovals > 0) {
        pending.openApprovals--;
        if (pending.openApprovals == 0) {
          pending.idleSince = DateTime.now();
        }
      }
      _tryCompleteBufferedDone(requestId);
    }
    return wasDeferred;
  }

  /// 用户明确不回答这张 deferred 卡。只关卡，不开新回合。
  Future<void> declineForm({
    required String peerId,
    required String approvalId,
  }) async {
    var tracked = _deferredForms.containsKey(approvalId) ||
        _approvalToRequest.containsKey(approvalId) ||
        _orphanedForms.containsKey(approvalId);
    tracked = tracked || await _isPersistedOpenForm(approvalId);
    if (!tracked) {
      throw const PeerApprovalExpiredException();
    }
    final sendControl =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    final sent = await sendControl(peerId, {
      'type': 'agent_form_resp',
      'approval_id': approvalId,
      'action': 'decline',
    });
    if (!sent) {
      throw Exception('表单发送失败，请确认配对设备在线后重试');
    }
    _deferredForms.remove(approvalId);
    _approvalToRequest.remove(approvalId);
    _orphanedForms.remove(approvalId);
    // 主机也会广播 `agent_interaction_closed(declined)`；这里先收一次，
    // 界面不用等回包。重复到达时卡片已有 `closed`，是幂等的。
    _applyInteractionClosed(approvalId, 'declined');
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
    // 回合结束时按它把卡片找回来。进程重启后内存账簿是空的，只剩消息上的这个字段。
    actionData['request_id'] = requestId;
    if (pending == null) {
      // Orphan: no live sendChat turn owns this approval (hub restarted
      // mid-approval and re-sent after reconnect, or agent_done raced ahead).
      // Republish so an open chat screen can still render the card — the tap
      // reaches submitApproval, which only needs the approval_id.
      // 本机没发起过这一轮时 `_requestAgents` 是空的（重启 / 别的设备发起的
      // 回合），帧里的 `agent_id` 就是远端 agent id，靠它仍能找到归属。
      final owner = _requestAgents[requestId];
      final remoteAgentId = owner?.remoteAgentId ?? data['agent_id'] as String?;
      final hostChannelId = _frameChannelId(data);
      if (remoteAgentId == null || remoteAgentId.isEmpty) {
        _log.warning(
          'agent_approval_req: no owning agent for requestId=$requestId — '
          'orphan approvalId=$approvalId has nowhere to render',
          tag: 'PeerApproval',
        );
        return;
      }
      unawaited(_publishOrphanCardToHub(
        peerId: peerId,
        remoteAgentId: remoteAgentId,
        cardId: approvalId,
        hostChannelId: hostChannelId,
        interactionType: 'action_confirmation',
        data: actionData,
      ));
      if (!_orphanApprovalController.isClosed) {
        _orphanApprovalController.add({
          ...actionData,
          'peer_id': peerId,
          'remote_agent_id': remoteAgentId,
          'channel_id': hostChannelId,
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
    var content = data['content'] as String? ?? '';
    if (requestId == null) return;
    final p = _pending[requestId];
    if (p == null) return;
    if (p.heldOnHost) {
      p.heldOnHost = false;
      p.idleSince = DateTime.now();
      final ack = p.queueAck;
      if (ack != null && !ack.isCompleted) ack.complete(false);
      ChatService().releaseQueuedMessage(requestId);
      ChatService().attachQueuedPeerTurn(p.toRecord(requestId));
    }
    // 新主机的 live 分片带 UTF-16 起始偏移。断线重连后主机把流改推到
    // 当前连接，live 分片可能和 resume 增量交错：重叠的裁掉，跳在前面的
    // 说明还有缺口，先交给 resume 补齐。
    final offset = data['offset'];
    if (offset is int) {
      final aligned = alignLiveChunk(
        content: content,
        offset: offset,
        receivedLength: p.receivedLength,
      );
      if (aligned.gap) {
        _scheduleReconnectCatchUp(p.peerId, requestId, p);
        return;
      }
      final rest = aligned.content;
      if (rest == null || rest.isEmpty) return;
      content = rest;
    }
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
    if (p.heldOnHost) {
      p.heldOnHost = false;
      p.idleSince = DateTime.now();
      final ack = p.queueAck;
      if (ack != null && !ack.isCompleted) ack.complete(false);
      ChatService().releaseQueuedMessage(requestId);
      ChatService().attachQueuedPeerTurn(p.toRecord(requestId));
    }
    final currentMode = (metadata['current_mode'] as String?)?.trim();
    if (currentMode != null && currentMode.isNotEmpty) {
      _patchCachedCurrent(
        p.remoteAgentId,
        PeerAgentMetaKind.modes,
        currentMode,
      );
    }
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

  Future<void> submitCommandApproval({
    required String peerId,
    required String approvalId,
    required String decision,
    required String argsDigest,
    String remember = 'once',
    String deviceId = '',
    String deviceName = '',
  }) async {
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'approval.resp',
      'approval_id': approvalId,
      'decision': decision,
      'remember': remember,
      'args_digest': argsDigest,
      if (deviceId.isNotEmpty) 'device_id': deviceId,
      if (deviceName.isNotEmpty) 'device_name': deviceName,
    });
  }

  Future<void> _onCmdInvoke(String peerId, Map<String, dynamic> data) async {
    Map<String, dynamic> result;
    try {
      result = await DeviceCommandRunner().handle(data);
    } catch (e) {
      result = {
        'type': 'cmd.result',
        'call_id': data['call_id'],
        'ok': false,
        'error': {
          'code': 'internal',
          'message': e.toString(),
          'retryable': false,
        },
      };
    }
    final reqId = data['req_id'];
    await PeerConnectionManager.instance.sendControl(peerId, {
      ...result,
      if (reqId != null) 'req_id': reqId,
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

  /// 主机放弃这张卡片了。reason 见帧里的 `reason` 字段（`timeout` / `cancelled`）。
  ///
  /// 收到就得把本地账簿一起收掉：卡片还留在 [_approvalToRequest] 里的话，它
  /// 继续撑着 `openApprovals`，`agent_done` 会被无限缓冲、这个回合永远不结束；
  /// 用户再点一下也只会发一条对端必然丢弃的裁决。
  void _onInteractionClosed(Map<String, dynamic> data) {
    final approvalId = data['approval_id'] as String?;
    if (approvalId == null || approvalId.isEmpty) {
      _log.warning('agent_interaction_closed: missing approval_id',
          tag: 'PeerApproval');
      return;
    }
    final reason = data['reason'] as String? ?? 'timeout';
    _log.info(
      'agent_interaction_closed: approvalId=$approvalId reason=$reason',
      tag: 'PeerApproval',
    );
    _applyInteractionClosed(approvalId, reason);
  }

  /// 把一张作废的卡片从本地账簿里摘掉，并通知 UI 收起可点态。
  ///
  /// 已提交过裁决的卡片只摘账簿、不改界面：那说明主机其实收到了答案，卡上的
  /// 勾是对的，不能因为一条迟到的 closed 帧把用户的真实操作抹掉（最坏情况是
  /// 提交与超时撞在一起，主机没采纳 —— 那就由对话里模型的下一句来说明）。
  void _applyInteractionClosed(String approvalId, String reason) {
    final answered = _submittedApprovals.containsKey(approvalId) ||
        _submittedForms.containsKey(approvalId);
    // deferred 卡收到关闭帧（拒绝、或已在别处作答）时正常收掉：等待位在主机
    // 那边已经摘了，再留着只会让用户点出「已失效」。
    _deferredForms.remove(approvalId);
    final requestId = _approvalToRequest.remove(approvalId);
    _orphanedApprovals.remove(approvalId);
    _orphanedForms.remove(approvalId);
    if (requestId != null) {
      final pending = _pending[requestId];
      if (pending != null && pending.openApprovals > 0) {
        pending.openApprovals--;
        if (pending.openApprovals == 0) pending.idleSince = DateTime.now();
      }
      _tryCompleteBufferedDone(requestId);
    }
    // 聊天页不在时没有人听上面的流，卡片会一直可点。写进消息本身，下次打开就是作废态。
    if (!answered) {
      unawaited(_persistInteractionClosed(approvalId, reason));
    }
    if (answered || _interactionClosedController.isClosed) return;
    _interactionClosedController.add((approvalId: approvalId, reason: reason));
  }

  /// 回合结束时，把还挂在这个回合上的卡片一并判为作废。
  ///
  /// `agent_interaction_closed` 只发一次（主机超时后自己往下跑），手机当时不
  /// 在线就收不到。回合结束是同一件事的第二个信号，用它兜底，免得屏幕上永远
  /// 留一张点不动的卡。只扫「没答过」的：答过的在 submit 时就已从这些表里摘掉。
  void _closeCardsOfRequest(String requestId, String reason) {
    // 已经 deferred 的卡还等着用户以后作答，不能被这一轮的结束收掉。
    final ids = <String>{
      for (final e in _approvalToRequest.entries)
        if (e.value == requestId && !_deferredForms.containsKey(e.key)) e.key,
      for (final e in _orphanedApprovals.entries)
        if (e.value['request_id'] == requestId &&
            !_deferredForms.containsKey(e.key))
          e.key,
      for (final e in _orphanedForms.entries)
        if (e.value['request_id'] == requestId &&
            !_deferredForms.containsKey(e.key))
          e.key,
    };
    for (final id in ids) {
      _applyInteractionClosed(id, reason);
    }
  }

  /// 作废帧到了，但聊天页可能不在。按交互 id 把库里的卡片收起来。
  Future<void> _persistInteractionClosed(
    String interactionId,
    String reason,
  ) async {
    if (interactionId.isEmpty) return;
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    try {
      final rows = await _db.findMessagesByMetadataMatch(interactionId);
      for (final row in rows) {
        await _writeClosedMetadata(
          row,
          (metadata) => metadataClosingInteraction(
            metadata,
            interactionId: interactionId,
            reason: reason,
          ),
        );
      }
    } catch (e) {
      _log.warning('persist interaction closed failed: $e',
          tag: 'PeerApproval', error: e);
    }
  }

  /// 回合结束时的兜底。进程重启后内存里没有卡片 id，作废帧也早就丢了，
  /// 只能按流式消息和 `request_id` 把还开着的卡收起来。
  Future<void> _persistTurnCardsClosed(
    _PendingRequest pending,
    String requestId,
    String reason,
  ) async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    try {
      final partialId = pending.partialMessageId;
      if (partialId != null && partialId.isNotEmpty) {
        final row = await _db.getMessageById(partialId);
        if (row != null) {
          await _writeClosedMetadata(
            row,
            (metadata) => metadataClosingOpenCards(metadata, reason: reason),
          );
        }
      }
      final channelId = pending.channelId;
      if (channelId.isEmpty || requestId.isEmpty) return;
      final rows = await _db.getChannelMessagesByMetadataMatch(
        channelId,
        requestId,
      );
      for (final row in rows) {
        await _writeClosedMetadata(
          row,
          (metadata) => metadataClosingOpenCards(metadata, reason: reason),
        );
      }
    } catch (e) {
      _log.warning('persist turn cards closed failed: $e',
          tag: 'PeerApproval', error: e);
    }
  }

  /// 库里是否还有一张没提交、没作废的表单卡。
  ///
  /// 这是 [submitForm] 的 known-guard 在进程重启后的凭据：卡是从
  /// [persistFormCard] 写的确定性行渲染出来的，内存账簿里当然找不到。
  Future<bool> _isPersistedOpenForm(String approvalId) async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return false;
    try {
      final row = await _db.getMessageById(
        PeerApprovalPayload.formCardMessageId(approvalId),
      );
      if (row == null) return false;
      final raw = row['metadata'];
      if (raw is! String || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return false;
      final form = decoded['form'];
      if (form is! Map) return false;
      if (form['submitted_values'] != null || form['closed'] != null) {
        return false;
      }
      return form['peer_form'] is Map;
    } catch (e) {
      _log.warning('read persisted form failed: $e',
          tag: 'PeerApproval', error: e);
      return false;
    }
  }

  /// 提交成功后把答案写回卡片行。
  ///
  /// 不写的话重启后又变回一张可以再答一次的表单，而主机早已收下这一份。
  Future<void> _persistFormSubmitted(
    String approvalId,
    Map<String, dynamic> values,
  ) async {
    if (!getIt.isRegistered<LocalDatabaseService>()) return;
    try {
      final row = await _db.getMessageById(
        PeerApprovalPayload.formCardMessageId(approvalId),
      );
      if (row == null) return;
      await _writeClosedMetadata(row, (metadata) {
        final raw = metadata['form'];
        if (raw is! Map) return null;
        final form = Map<String, dynamic>.from(raw);
        if (form['submitted_values'] != null) return null;
        form['submitted_values'] = values;
        metadata['form'] = form;
        return metadata;
      });
    } catch (e) {
      _log.warning('persist form submitted failed: $e',
          tag: 'PeerApproval', error: e);
    }
  }

  /// 同一行 metadata 的读改写串行链，避免 deferred / turn_ended 互相覆盖。
  ///
  /// 两张写都可能先读到同一份旧快照、再各写各的：`turn_ended` 会盖上
  /// `closed`，把刚写进去的 `deferred` 冲掉，卡片重启后变成不可答。
  /// 这里按消息 id 排队，并且每次都在锁内重读最新行再改。
  final SerialTaskQueue<String> _metadataWrites = SerialTaskQueue<String>();

  Future<void> _writeClosedMetadata(
    Map<String, dynamic> row,
    Map<String, dynamic>? Function(Map<String, dynamic> metadata) close,
  ) {
    final id = row['id'] as String? ?? '';
    if (id.isEmpty) return Future<void>.value();
    return _metadataWrites.run(id, () async {
      final fresh = await _db.getMessageById(id);
      if (fresh == null) return;
      final raw = fresh['metadata'];
      if (raw is! String || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final value = close(Map<String, dynamic>.from(decoded));
      if (value == null) return;
      await _db.updateMessageMetadata(id, value);
    });
  }

  void _finishPending(String requestId, Map<String, dynamic> data) {
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    _stopCatchUp(p);
    // 回合跑完了 → 主机当然收下了；排队回执可能在断线上丢了。
    final ack = p.queueAck;
    if (ack != null && !ack.isCompleted) ack.complete(true);
    _clearPersistedTurn(requestId);
    _closeCardsOfRequest(requestId, 'turn_ended');
    unawaited(_persistTurnCardsClosed(p, requestId, 'turn_ended'));
    final metadata = (data['metadata'] as Map?)?.cast<String, dynamic>();
    p.completer.complete(PeerChatResult(
      content: data['content'] as String? ?? '',
      metadata: data['deferred'] == true
          ? {...?metadata, 'deferred': true}
          : metadata,
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

  void _onAgentQueued(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final pending = _pending[requestId];
    if (pending == null) return;
    pending.heldOnHost = true;
    final ack = pending.queueAck;
    if (ack != null && !ack.isCompleted) ack.complete(true);
  }

  void _onError(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final p = _pending.remove(requestId);
    if (p == null || p.completer.isCompleted) return;
    _stopCatchUp(p);
    final ack = p.queueAck;
    if (ack != null && !ack.isCompleted) {
      ack.completeError(
        Exception(data['message'] as String? ?? 'Peer agent error'),
      );
    }
    _clearPersistedTurn(requestId);
    _closeCardsOfRequest(requestId, 'turn_ended');
    unawaited(_persistTurnCardsClosed(p, requestId, 'turn_ended'));
    p.completer.completeError(
      Exception(data['message'] as String? ?? 'Peer agent error'),
    );
  }

  // ── agent 列表注入 / 清理 ──────────────────────────────────────────────

  void _onConnectionEvent(PeerConnectionEvent event) {
    if (event.type == PeerConnectionEventType.connected) {
      // 还没登录就要名单，主机会回 pouch_login_required，登录页会被反复推掉。
      if (_pouchLoginReady(event.peerId)) _greetHost(event.peerId);
      if (_handlersReadyForResume) {
        unawaited(_resumeSuspendedTurns(event.peerId));
      }
      _flushReconcileHints(event.peerId);
    } else if (event.type == PeerConnectionEventType.disconnected) {
      _dropFreshCommands(event.peerId);
      _suspendPendingForPeer(event.peerId);
      // 主动丢弃半开连接后马上就会重连。仍然要 suspend 在途 turn（重连后
      // 才会发 resume），但不必把 agent 闪成离线再闪回来。
      final data = event.data;
      final stale = data is Map && data['stale'] == true;
      if (!stale) {
        unawaited(_markPeerAgentsOffline(event.peerId));
      }
    }
  }

  /// PeerConnectionManager.resumeAll 的征询钩子：该 peer 是否存在尚未完成的
  /// sendChat turn（含审批待决）。
  ///
  /// 目前只对 worker 生效（CLI 流断连会被 hub 补错误终态）。普通 agent turn
  /// 可以安全跨连接，重连后由 resume_req 断点续传，因此不阻止探活重建。
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

  /// 发送成功后确认 `agent_chat` 真的到了主机。
  ///
  /// WebSocket / tunnel 的 send 只保证写进本地 socket，半开连接上会静默
  /// 成功。主机在收到 `agent_chat` 时同步 claim turn，因此发出后一直没收到
  /// 任何主机帧时，发一次 resume_req：streaming / done / error 说明主机有这
  /// 轮对话，`lost` 说明这一帧没到。命中 `lost` 立刻失败，让控制器把消息交
  /// 回输入框，而不是等连接活性超时（120s）后报一个含糊的「任务已丢失」。
  void _scheduleDeliveryProbe(
    String requestId,
    _PendingRequest p,
    String peerId,
  ) {
    p.deliveryProbeTimer?.cancel();
    p.deliveryProbeTimer = Timer(_effectiveDeliveryProbeDelay, () {
      p.deliveryProbeTimer = null;
      if (p.completer.isCompleted || p.heardFromHost) return;
      // 连接已断 / 已有续传探测在跑 → 交给断连恢复路径。
      if (p.suspendedSince != null || p.resumeInFlight) return;
      // 排队路径有 agent_queued + 20s ack 兜底；未 claim 前 resume 会误报 lost。
      if (p.heldOnHost) return;

      p.resumeInFlight = true;
      p.resumePurpose = _ResumePurpose.deliveryProbe;
      p.resumeBaseLength = p.receivedLength;
      _log.info(
        'delivery probe requestId=$requestId '
        '(no host frame in ${_effectiveDeliveryProbeDelay.inMilliseconds}ms)',
        tag: 'PeerApproval',
      );
      unawaited(_sendDeliveryProbe(peerId, requestId, p));
    });
  }

  Future<void> _sendDeliveryProbe(
    String peerId,
    String requestId,
    _PendingRequest p,
  ) async {
    final sent = await _sendResumeReq(peerId, requestId, p);
    if (!sent) {
      p.resumeInFlight = false;
      p.resumePurpose = _ResumePurpose.none;
      p.resumeBaseLength = null;
      return;
    }
    // 只探测一次：旧 hub 不认识 resume_req，反复发只会制造噪声。
    // 应答丢失时退回到原有的慢路径（活性超时 / 断连续传）。
    _watchResumeResponse(peerId, requestId, 0, failOnExhausted: false);
  }

  /// 投递确认判定「主机没收到」后，用同一个 request_id 原样补发一次。
  ///
  /// 主机在入口按 request_id 去重（`TurnLog::accept_once`），所以即便第一帧
  /// 其实到了、只是确认帧丢了，补发也不会让同一回合跑两遍。补发成功后重新
  /// 挂投递确认：第二次仍 `lost` 才真正判失败。
  Future<void> _resendAgentChat(
    String peerId,
    String requestId,
    _PendingRequest p,
  ) async {
    final original = p.agentChatFrame;
    if (original == null || p.completer.isCompleted) return;
    // 带上已收到的长度：主机若其实已经受理，就只回缺的那一段，
    // 不会把客户端已经显示的正文再回放一遍。
    final frame = <String, dynamic>{
      ...original,
      'known_content_length': p.receivedLength,
    };
    final override = debugSendControlOverride;
    final bool sent;
    if (override != null) {
      sent = await override(peerId, frame);
    } else {
      sent = await PeerConnectionManager.instance.sendControl(
        peerId,
        frame,
        // 连接不可用时也等待重连补发；用户已经等了一会儿，不要立刻报错。
        waitForReconnect: _controlReconnectWait,
        abortWhen: () =>
            p.completer.isCompleted || !identical(_pending[requestId], p),
      );
    }
    if (p.completer.isCompleted || !identical(_pending[requestId], p)) return;
    if (!sent) {
      _log.warning('agent_chat resend failed requestId=$requestId');
      _markReconcileNeeded(requestId);
      _onError({
        'request_id': requestId,
        'message': '消息未能送达主机，请重新发送',
      });
      return;
    }
    if (p.heardFromHost) return;
    _log.info(
      'agent_chat resent requestId=$requestId — re-arming delivery probe',
      tag: 'PeerApproval',
    );
    _scheduleDeliveryProbe(requestId, p, peerId);
  }

  Duration get _effectiveDeliveryProbeDelay =>
      debugDeliveryProbeDelayOverride ?? deliveryProbeDelay;

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

  /// 重连续传成功后，主机这条回合的转发通道仍挂在旧连接上，不会自动
  /// 往新连接续推。按 [reconnectCatchUpInterval] 短周期补拉，直到 done /
  /// error；再次断线时暂停，重连后由 [_resumeSuspendedTurns] 重新接上。
  void _scheduleReconnectCatchUp(
    String peerId,
    String requestId,
    _PendingRequest p,
  ) {
    p.catchUpTimer?.cancel();
    p.catchUpTimer = Timer.periodic(_effectiveCatchUpInterval, (timer) {
      if (p.completer.isCompleted || !identical(_pending[requestId], p)) {
        timer.cancel();
        p.catchUpTimer = null;
        return;
      }
      if (p.suspendedSince != null ||
          p.upstreamReconnectingSince != null ||
          p.resumeInFlight ||
          p.openApprovals > 0) {
        return;
      }
      p.lastStallProbeAt = DateTime.now();
      p.resumeInFlight = true;
      p.resumePurpose = _ResumePurpose.stallProbe;
      p.resumeBaseLength = p.receivedLength;
      unawaited(() async {
        final sent = await _sendResumeReq(peerId, requestId, p);
        if (!sent) {
          p.resumeInFlight = false;
          p.resumePurpose = _ResumePurpose.none;
          p.resumeBaseLength = null;
          return;
        }
        _watchResumeResponse(peerId, requestId, 0, failOnExhausted: false);
      }());
    });
  }

  void _stopCatchUp(_PendingRequest p) {
    p.catchUpTimer?.cancel();
    p.catchUpTimer = null;
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
      if (!failOnExhausted) {
        // 探测类请求（停滞补拉 / 投递确认）失败只复位，不判死 turn。
        _log.warning(
          '${cur.resumePurpose.name} requestId=$requestId timed out — '
          'not failing the turn',
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

  Duration get _effectiveQueueAckTimeout =>
      debugQueueAckTimeoutOverride ?? const Duration(seconds: 20);

  Duration get _effectiveCatchUpInterval =>
      debugReconnectCatchUpIntervalOverride ?? reconnectCatchUpInterval;

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
  void _onTurnResumeResp(Map<String, dynamic> data, {String? fromPeerId}) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    // 先补交互卡。帧在生成时只发过一次，断线那一下就丢了，续传带回的这张
    // 可能是唯一的机会。放在 `_pending` 判空之前 —— turn 恰好刚被清掉时，
    // 卡片更需要走孤儿路径而不是被一起丢掉。
    final peerForInteraction =
        _pending[requestId]?.peerId ?? _requestAgents[requestId]?.peerId;
    if (peerForInteraction != null) {
      _redispatchPendingInteraction(
        peerForInteraction,
        data['pending_interaction'],
      );
    }
    final p = _pending[requestId];
    if (p == null) {
      // 主机重连后主动补发的终态帧。App 这边的在途记录可能已经清掉
      // （进程重启 / 超时清理 / 聊天页关掉），不能再走 _finishPending，
      // 否则没有会话可落。只标记一次历史对账，让聊天页从远端把这条
      // 回复拉回来，避免把同一段内容重复插进本地库。
      _reconcileOrphanTerminal(requestId, data, fromPeerId);
      return;
    }
    final purpose = p.resumePurpose;
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
    // 主机认得这一轮：排队确认帧（agent_queued）可能正好丢在断线上，
    // resume 的应答同样能证明它收下了。lost 交给下面的失败路径。
    final queueAck = p.queueAck;
    if (queueAck != null && !queueAck.isCompleted) {
      queueAck.complete(status != 'lost');
    }
    switch (status) {
      case 'streaming':
        // 续传成功 —— idle 看门狗从此刻重新计时。
        p.idleSince = DateTime.now();
        // 断连续传成功：旧连接已经不在转发流里，主机不会主动续推。
        // 按短周期补拉后续分片和终态，别让用户干等 180s 的停滞探测。
        if (purpose == _ResumePurpose.suspend) {
          _scheduleReconnectCatchUp(p.peerId, requestId, p);
        }
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
        // 投递探活：主机不认识这轮 —— 且我们没收到过任何业务帧 ——
        // 说明 agent_chat 这一帧压根没到主机（半开连接 / relay 丢帧）。
        // 快速失败，把消息交回输入框重试；等 120s 活性超时只会更糟。
        if (purpose == _ResumePurpose.deliveryProbe && !p.heardFromHost) {
          // 先原样补发一次：主机按 request_id 去重，重复执行是安全的。
          if (p.agentChatFrame != null && p.agentChatResendCount == 0) {
            p.agentChatResendCount++;
            _log.warning(
              'agent_chat missing at hub requestId=$requestId — resending once',
              tag: 'PeerApproval',
            );
            unawaited(_resendAgentChat(p.peerId, requestId, p));
            break;
          }
          _log.warning(
            'agent_chat never reached hub requestId=$requestId '
            '— fail fast for resend',
            tag: 'PeerApproval',
          );
          // 极少数情况下主机已把消息排进内存队列、只是 agent_queued 丢了；
          // 若它之后真的跑了，历史同步还能把回复补回对话。
          _markReconcileNeeded(requestId);
          _onError({
            'request_id': requestId,
            'message': '消息未能送达主机，请重新发送',
          });
          break;
        }
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

  /// 把 hub 补交回来的交互帧走一遍实时帧的分发。
  /// 只可能是这两类：它们的本地簿记（孤儿缓存、已答回填、openApprovals
  /// 计数、`_approvalToRequest`）全在 [_onFormReq] / [_onApprovalReq] 里，
  /// 若当成 metadata 直接并进消息，这些簿记会被绕过 —— 用户点下去会被
  /// 判成过期卡（`PeerApprovalExpiredException`），卡片看着能点其实发不出去。
  void _redispatchPendingInteraction(String peerId, Object? frame) {
    if (frame is! Map) return;
    final data = Map<String, dynamic>.from(frame);
    switch (data['type']) {
      case 'agent_form_req':
        _log.info(
          'pending_interaction: re-dispatching form approvalId='
          '${data['approval_id']}',
          tag: 'PeerApproval',
        );
        _onFormReq(peerId, data);
        break;
      case 'agent_approval_req':
        _log.info(
          'pending_interaction: re-dispatching approval approvalId='
          '${data['approval_id']}',
          tag: 'PeerApproval',
        );
        _onApprovalReq(peerId, data);
        break;
      default:
        _log.warning(
          'pending_interaction: unsupported frame type=${data['type']}',
          tag: 'PeerApproval',
        );
    }
  }

  bool _pouchLoginReady(String peerId) {
    final session = PouchChannel.active?.session;
    if (session == null || session.hostPeerId != peerId) return false;
    return session.isLoggedIn(DateTime.now().millisecondsSinceEpoch);
  }

  /// 登录好主机后报上本机能力，要 Agent 名单，再补问一次没答的卡片。
  ///
  /// 主机建连时会自己补发一次，但那一刻 App 可能还没登录、没订阅控制流，
  /// 帧会被 `pouch_login_required` 挡掉或落到没人听的地方；登录完成后主动
  /// 问一次，时机才在 App 这边。
  void _greetHost(String peerId) {
    unawaited(DeviceHello.send(peerId).catchError((Object e) {
      _log.warning('device.hello failed: $e', tag: _tag);
    }));
    _requestAgentList(peerId);
    _requestPendingInteractions(peerId);
  }

  /// 通道刚装上时，只有已经连着的主机才拉名单。还没连上的等下一次 connected。
  void _greetHostIfConnected(String peerId) {
    final id = peerId.trim();
    if (id.isEmpty || !_peerIsConnected(id)) return;
    _greetHost(id);
  }

  bool _peerIsConnected(String peerId) {
    final override = debugConnectedPeerIdsOverride;
    if (override != null) return override.contains(peerId);
    return PeerConnectionManager.instance.connectedPeerIds.contains(peerId);
  }

  /// [peerId] 当前是否已连接（单测中会走 [debugConnectedPeerIdsOverride]）。
  bool isPeerConnected(String peerId) => _peerIsConnected(peerId);

  /// 通知对端下发最新 `agent_list_resp`（后台异步落库，不挂等待定时器）。
  void requestAgentListRefresh(String peerId) {
    if (!_peerIsConnected(peerId)) return;
    _requestAgentList(peerId);
  }

  void _requestAgentList(String peerId) {
    final send =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    unawaited(send(peerId, {
      'type': 'agent_list_req',
    }));
  }

  /// 问主机还有哪些卡片没人答。主机把还悬空的帧原样回来，App 走
  /// `_onFormReq` 的同一条路渲染并落库；重复投递由确定性卡片行去重。
  void _requestPendingInteractions(String peerId) {
    final send =
        debugSendControlOverride ?? PeerConnectionManager.instance.sendControl;
    unawaited(send(peerId, {
      'type': 'agent_pending_interactions_req',
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
    if (!_peerIsConnected(peerId)) {
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
        _forgetRecentlyCreatedAgent(peerId, remoteId);

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
        final node = AgentNodeInfo.fromAgentListEntry(raw);
        final online = node.online && (!manageable || (enabled && running));
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

        final metadata = <String, dynamic>{
          'source_peer_id': peerId,
          'source_peer_name': peerName,
          'remote_agent_id': remoteId,
          if (hostRoster != null)
            'roster_hub_fingerprint': hostRoster.fingerprint,
          ...node.toMetadata(),
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
        };
        if (remoteId == SheService.sheId) {
          applyHostSheModelMetadata(metadata, {
            'has_main_model': raw['has_main_model'] == true,
            'model': raw['model'],
            'base_url': raw['base_url'],
          });
        }
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
          metadata: metadata,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        );

        if (existing == null) {
          await _db.createRemoteAgent(agent);
        } else {
          await _db.updateRemoteAgent(agent);
        }
        final syncClients = raw['sync_client_sessions'];
        if (syncClients is bool) {
          await rememberClientSessionSync(
            localAgentId: localId,
            remoteAgentId: remoteId,
            enabled: syncClients,
          );
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
        // 惜宝的模型不在本机注册表里。名单一到就向主机要，聊天框不用再等一轮。
        if (remoteId == SheService.sheId) {
          unawaited(fetchModels(peerId: peerId, remoteAgentId: remoteId));
        }
      }
      unawaited(syncAllPeerAgentsReadState(peerId));
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
    // 惜宝固定用本机灵宠图。对端若还在发旧爪印文件，不落盘、也不覆盖。
    if (SheService.isSheIdentity(raw['id'] as String?) ||
        SheService.isSheIdentity(existing?.id, existing?.metadata)) {
      return SheService.sheAvatar;
    }

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
      if (_isRecentlyCreatedAgent(peerId, a.remoteAgentId)) continue;
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

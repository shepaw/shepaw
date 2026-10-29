/// Persisted in-flight peer agent turn, plus helpers for history-sync
/// so a process kill can resume instead of starting a second turn.
library;

import 'dart:convert';

/// Thrown when [PeerAgentClientService.sendChat] is asked to start a new
/// turn on a session that already has one running (including a restored
/// turn from a previous process).
class PeerTurnInFlightException implements Exception {
  const PeerTurnInFlightException();

  @override
  String toString() => 'PeerTurnInFlightException';
}

/// Disk record of a peer `agent_chat` that has not reached a terminal
/// `agent_done` / error / cancel. Survives App process death.
class PeerInflightTurnRecord {
  final String requestId;
  final String peerId;
  final String remoteAgentId;
  final String localAgentId;
  final String channelId;
  final String sessionId;
  final String userMessageId;
  final String userId;
  final String userName;
  final String agentName;
  final int receivedLength;
  final String accumulatedContent;
  final String? partialMessageId;

  /// 最近一帧工具状态（`pending` / `in_progress` / `completed` / `failed`）。
  /// 进程被杀后恢复在途回合时，仍要用它判断「正文停了、工具还在跑」，
  /// 与主机 `turn_followup_can_start` 的 `answer_settled` 保持一致。
  final String lastToolStatus;
  final int startedAtMs;
  final int updatedAtMs;

  const PeerInflightTurnRecord({
    required this.requestId,
    required this.peerId,
    required this.remoteAgentId,
    required this.localAgentId,
    required this.channelId,
    required this.sessionId,
    required this.userMessageId,
    required this.userId,
    required this.userName,
    required this.agentName,
    required this.receivedLength,
    this.accumulatedContent = '',
    this.partialMessageId,
    this.lastToolStatus = '',
    required this.startedAtMs,
    required this.updatedAtMs,
  });

  static const int maxAccumulatedChars = 200000;

  PeerInflightTurnRecord copyWith({
    int? receivedLength,
    String? accumulatedContent,
    String? partialMessageId,
    String? lastToolStatus,
    int? updatedAtMs,
  }) {
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
      receivedLength: receivedLength ?? this.receivedLength,
      accumulatedContent: accumulatedContent ?? this.accumulatedContent,
      partialMessageId: partialMessageId ?? this.partialMessageId,
      lastToolStatus: lastToolStatus ?? this.lastToolStatus,
      startedAtMs: startedAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
    );
  }

  Map<String, Object?> toMap() => {
        'request_id': requestId,
        'peer_id': peerId,
        'remote_agent_id': remoteAgentId,
        'local_agent_id': localAgentId,
        'channel_id': channelId,
        'session_id': sessionId,
        'user_message_id': userMessageId,
        'user_id': userId,
        'user_name': userName,
        'agent_name': agentName,
        'received_length': receivedLength,
        'accumulated_content': clipAccumulated(accumulatedContent),
        'partial_message_id': partialMessageId,
        'last_tool_status': lastToolStatus,
        'started_at': startedAtMs,
        'updated_at': updatedAtMs,
      };

  factory PeerInflightTurnRecord.fromMap(Map<String, Object?> row) {
    return PeerInflightTurnRecord(
      requestId: row['request_id'] as String? ?? '',
      peerId: row['peer_id'] as String? ?? '',
      remoteAgentId: row['remote_agent_id'] as String? ?? '',
      localAgentId: row['local_agent_id'] as String? ?? '',
      channelId: row['channel_id'] as String? ?? '',
      sessionId: row['session_id'] as String? ?? '',
      userMessageId: row['user_message_id'] as String? ?? '',
      userId: row['user_id'] as String? ?? '',
      userName: row['user_name'] as String? ?? '',
      agentName: row['agent_name'] as String? ?? '',
      receivedLength: (row['received_length'] as num?)?.toInt() ?? 0,
      accumulatedContent: row['accumulated_content'] as String? ?? '',
      partialMessageId: row['partial_message_id'] as String?,
      lastToolStatus: row['last_tool_status'] as String? ?? '',
      startedAtMs: (row['started_at'] as num?)?.toInt() ?? 0,
      updatedAtMs: (row['updated_at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Clip persisted stream text so a runaway turn cannot blow up SQLite.
String clipAccumulated(String text, {int maxChars = PeerInflightTurnRecord.maxAccumulatedChars}) {
  if (text.length <= maxChars) return text;
  return text.substring(text.length - maxChars);
}

/// Aligns with app suspendWaitHardCap so a turn paused on an approval
/// can still be resumed after the phone was away for up to a day.
const Duration kPeerInflightTurnTtl = Duration(hours: 25);

bool isPeerInflightTurnExpired(
  PeerInflightTurnRecord record, {
  required DateTime now,
  Duration ttl = kPeerInflightTurnTtl,
}) {
  if (record.updatedAtMs <= 0 && record.startedAtMs <= 0) return true;
  final stamp = record.updatedAtMs > 0 ? record.updatedAtMs : record.startedAtMs;
  return now.millisecondsSinceEpoch - stamp > ttl.inMilliseconds;
}

/// Local channel row considered by history-sync deletion.
class PeerHistorySyncLocalRow {
  final String id;
  final String senderType;
  final String content;
  final String? metadataJson;

  /// `reply_to_id` of the row, when any. Lets the sync deletion pass find
  /// local agent replies whose user-prompt anchor is being replaced by a
  /// remote-owned `peerhist_*` row.
  final String? replyToId;

  const PeerHistorySyncLocalRow({
    required this.id,
    required this.senderType,
    required this.content,
    this.metadataJson,
    this.replyToId,
  });
}

/// One ordered entry of the remote transcript, used by turn-linkage analysis.
class PeerHistoryRemoteEntry {
  final String role;
  final String content;

  const PeerHistoryRemoteEntry({required this.role, required this.content});
}

String peerHistoryRoleContentKey(String role, String content) =>
    '$role\n${content.trim()}';

/// Whether a synced (remote-owned) row's content can stand in for a locally
/// produced final message. Either-direction prefix after trim, so trailing
/// drift (a clipped resume delta, a "[Stopped]" suffix) still counts as the
/// same turn's content. Empty final content never matches — progress-only
/// replies must be kept.
bool peerSyncedRowCoversFinalContent(String rowContent, String finalContent) {
  final remote = rowContent.trim();
  final local = finalContent.trim();
  if (local.isEmpty || remote.isEmpty) return false;
  return remote == local || remote.startsWith(local) || local.startsWith(remote);
}

/// 主机形态的消息 id：`peerhist_{message_id}`。
///
/// 主机 agent 会话的 `message.created` 与历史同步都用这个形态。本机落库时就得
/// 按它铸 id，主机回包才是同一条 —— 否则 `collapse` 要把本机那条行删了重建，
/// 指向它的引用跟着悬空（气泡上渲染成「原消息不可用」）。
String peerhistMessageId(String? rawId) {
  final id = rawId?.trim() ?? '';
  if (id.isEmpty) return '';
  return id.startsWith('peerhist_') ? id : 'peerhist_$id';
}

/// [peerhistMessageId] 的逆：上行帧里要发裸 id —— 前缀归主机自己加，
/// 原样发过去会变成 `peerhist_peerhist_*`。
String bareMessageId(String id) {
  const prefix = 'peerhist_';
  return id.startsWith(prefix) ? id.substring(prefix.length) : id;
}

/// 助手回复对外的稳定主键：`peerhist_{requestId}`。
///
/// 主机 `message.created` 和历史同步都用 request id 当助手消息 id。本机终态
/// 若再另造一个 uuid，两条通道就会各留一行。
String peerhistAgentMessageId(String? requestId) =>
    peerhistMessageId(requestId);

/// 把本机流式阶段记下的 thinking 补到一条还没有进度块的行上。
///
/// 已有非空 `progress_content` 时不覆盖。没有可补的进度时返回 null。
Map<String, dynamic>? peerProgressMetadataToMerge({
  required Map<String, dynamic>? existing,
  required Map<String, dynamic>? incoming,
}) {
  final incomingProgress = incoming?['progress_content'];
  if (incomingProgress is! String || incomingProgress.trim().isEmpty) {
    return null;
  }
  final existingProgress = existing?['progress_content'];
  if (existingProgress is String && existingProgress.trim().isNotEmpty) {
    return null;
  }
  final merged = Map<String, dynamic>.from(existing ?? {});
  merged['progress_content'] = incomingProgress;
  merged['collapsible'] = incoming?['collapsible'] ?? true;
  final title = incoming?['collapsible_title'];
  if (title is String && title.isNotEmpty) {
    merged['collapsible_title'] = title;
  } else {
    merged.putIfAbsent('collapsible_title', () => 'Details');
  }
  final autoCollapse = incoming?['auto_collapse'];
  merged['auto_collapse'] = autoCollapse ?? merged['auto_collapse'] ?? true;
  final steps = incoming?['progress_steps'];
  if (steps is List && steps.isNotEmpty) merged['progress_steps'] = steps;
  return merged;
}

/// Hub 写入 `peerhist_{requestId}` 时要删掉的本机行，以及要带走的进度 metadata。
///
/// 裸 id（用户消息透传的那个）一定删。助手回复的本机副本 id 是另一个 uuid，
/// 只能靠 metadata.request_id 认。正在流式、或用户已停止的行留下。
class PeerhistInsertCollapse {
  final List<String> deleteIds;
  final Map<String, dynamic>? metadata;

  /// 这次重键要跟着搬的引用：本机裸 id → 主机 `peerhist_*` id。
  ///
  /// 发消息那一刻用户行是裸 id，助手回复行记的 `reply_to_id` 就是那个裸 id；
  /// collapse 之后用户行改叫 `peerhist_<同一个 id>`。引用不跟着搬就悬空，
  /// 整列重建时气泡上会渲染出「原消息不可用」。
  final List<({String from, String to})> replyToRewrites;

  const PeerhistInsertCollapse({
    required this.deleteIds,
    required this.metadata,
    this.replyToRewrites = const [],
  });
}

PeerhistInsertCollapse collapseLocalPeerTurnOnPeerhistInsert({
  required String peerhistId,
  required Map<String, dynamic>? eventMetadata,
  required Iterable<({String id, String? metadataJson})> localRows,
}) {
  final requestId = peerhistId.startsWith('peerhist_')
      ? peerhistId.substring('peerhist_'.length)
      : '';
  final deleteIds = <String>[];
  if (requestId.isNotEmpty && requestId != peerhistId) {
    deleteIds.add(requestId);
  }
  // 本机那条裸 id 行换成了 `peerhist_<同一个 id>`，只是在库里换了名字，
  // 指向它的引用要跟着搬（否则就是「原消息不可用」）。
  final rewrites = deleteIds.isEmpty
      ? const <({String from, String to})>[]
      : [(from: requestId, to: peerhistId)];
  var meta = eventMetadata == null
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(eventMetadata);
  var hasMeta = eventMetadata != null && eventMetadata.isNotEmpty;
  if (requestId.isEmpty) {
    return PeerhistInsertCollapse(
      deleteIds: deleteIds,
      metadata: hasMeta ? meta : null,
      replyToRewrites: rewrites,
    );
  }
  for (final row in localRows) {
    if (row.id.isEmpty || row.id.startsWith('peerhist_')) continue;
    Map<String, dynamic>? decoded;
    final raw = row.metadataJson;
    if (raw != null && raw.isNotEmpty) {
      try {
        final value = jsonDecode(raw);
        if (value is Map) decoded = Map<String, dynamic>.from(value);
      } catch (_) {}
    }
    if (row.id == requestId) {
      if (!deleteIds.contains(row.id)) deleteIds.add(row.id);
      continue;
    }
    if (decoded == null || decoded['request_id'] != requestId) continue;
    final status = decoded['status'];
    if (status == 'streaming' || status == 'stopped') continue;
    deleteIds.add(row.id);
    final merged = peerProgressMetadataToMerge(
      existing: hasMeta ? meta : null,
      incoming: decoded,
    );
    if (merged != null) {
      meta = merged;
      hasMeta = true;
    }
  }
  return PeerhistInsertCollapse(
    deleteIds: deleteIds,
    metadata: hasMeta ? meta : null,
    replyToRewrites: rewrites,
  );
}

bool peerHistorySyncRowIsStreaming(String? metadataJson) {
  if (metadataJson == null || metadataJson.isEmpty) return false;
  return metadataJson.contains('"status":"streaming"') ||
      metadataJson.contains('"status": "streaming"');
}

/// Local ids that must be deleted so the channel stays pull-authoritative,
/// without wiping a live turn that the remote transcript does not yet have.
///
/// Keep a local row when:
/// - its id is already in [remoteIds] (just upserted);
/// - it is listed in [preserveIds] (inflight user / partial);
/// - it is a `status: streaming` flush row whose content is NOT yet covered
///   by the remote transcript (a live turn still ahead of the remote);
/// - it is a non-`peerhist_*` row whose role+content is not in the remote
///   transcript AND which is not turn-linked to a replaced user prompt (a
///   message the phone created that the agent has not committed yet).
///
/// Deletion rules beyond the plain content match:
/// - A `status: streaming` row outside [preserveIds] belongs to a dead turn
///   (process kill + resume lost/expired, etc.). Once the remote transcript
///   contains an agent message covering its content (prefix match), the orphan
///   must be deleted — otherwise it survives forever next to the `peerhist_*`
///   full message, showing "half reply + full reply" as two bubbles.
/// - Turn linkage: when a local user row is deleted because the remote
///   transcript owns that prompt AND the remote has an answer for it, local
///   agent rows replying to that prompt ([PeerHistorySyncLocalRow.replyToId])
///   are the same turn's local copy — delete them even when their content
///   drifted from the remote answer (whitespace, progress folding). Otherwise
///   the local copy lingers next to the `peerhist_*` row with a dangling
///   replyTo ("原消息不可用" quote header).
Set<String> localMessageIdsToDeleteOnPeerHistorySync({
  required Iterable<PeerHistorySyncLocalRow> localRows,
  required Set<String> remoteIds,
  required Set<String> remoteRoleContentKeys,
  required Set<String> preserveIds,
  /// Raw contents of the remote transcript's agent messages, used to decide
  /// whether an orphan streaming row is already covered by a fuller remote
  /// version.
  Iterable<String> remoteAgentContents = const [],
  /// Ordered remote transcript (oldest → newest) for turn-linkage analysis.
  Iterable<PeerHistoryRemoteEntry> remoteTranscript = const [],
}) {
  final rows = localRows.toList();
  final transcript = remoteTranscript.toList();
  final pool = <PeerHistorySyncLocalRow>[
    for (final row in rows)
      if (row.id.isNotEmpty &&
          !row.id.startsWith('peerhist_') &&
          !remoteIds.contains(row.id) &&
          !preserveIds.contains(row.id) &&
          !peerHistorySyncRowIsStreaming(row.metadataJson))
        row,
  ];

  bool answeredUser(int index) {
    if (index + 1 >= transcript.length) return false;
    return transcript[index + 1].role != 'user';
  }

  PeerHistorySyncLocalRow? takeMatch(String role, String content) {
    for (var i = 0; i < pool.length; i++) {
      final row = pool[i];
      final rowRole = row.senderType == 'user' ? 'user' : 'agent';
      if (rowRole != role) continue;
      if (peerHistoryRoleContentKey(rowRole, row.content) !=
          peerHistoryRoleContentKey(role, content)) {
        continue;
      }
      return pool.removeAt(i);
    }
    return null;
  }

  final supersedingUserIds = <String>{};
  if (transcript.isEmpty) {
    for (final key in remoteRoleContentKeys) {
      final split = key.split('\n');
      if (split.isEmpty) continue;
      final role = split.first;
      final content = split.length == 1 ? '' : split.sublist(1).join('\n');
      final match = takeMatch(role, content);
      if (match != null && role == 'user') supersedingUserIds.add(match.id);
    }
  } else {
    for (var i = 0; i < transcript.length; i++) {
      final entry = transcript[i];
      final match = takeMatch(entry.role, entry.content);
      if (match == null) continue;
      if (entry.role == 'user' && answeredUser(i)) {
        supersedingUserIds.add(match.id);
      }
    }
  }

  bool turnLinked(PeerHistorySyncLocalRow row) {
    final anchor = row.replyToId;
    return anchor != null && supersedingUserIds.contains(anchor);
  }

  final toDelete = <String>{
    for (final row in rows)
      if (row.id.isNotEmpty &&
          !remoteIds.contains(row.id) &&
          !preserveIds.contains(row.id) &&
          !pool.contains(row) &&
          !peerHistorySyncRowIsStreaming(row.metadataJson))
        row.id,
  };
  for (final row in pool) {
    if (row.senderType != 'user' && turnLinked(row)) toDelete.add(row.id);
  }
  for (final row in rows) {
    if (row.id.isEmpty || toDelete.contains(row.id)) continue;
    if (remoteIds.contains(row.id) || preserveIds.contains(row.id)) continue;
    if (!peerHistorySyncRowIsStreaming(row.metadataJson)) {
      if (row.id.startsWith('peerhist_')) toDelete.add(row.id);
      continue;
    }
    final covered = row.content.isNotEmpty &&
        remoteAgentContents.any((c) => c.startsWith(row.content));
    if (covered || turnLinked(row)) toDelete.add(row.id);
  }
  return toDelete;
}

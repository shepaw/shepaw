/// Persisted in-flight peer agent turn, plus helpers for history-sync
/// so a process kill can resume instead of starting a second turn.
library;

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
    required this.startedAtMs,
    required this.updatedAtMs,
  });

  static const int maxAccumulatedChars = 200000;

  PeerInflightTurnRecord copyWith({
    int? receivedLength,
    String? accumulatedContent,
    String? partialMessageId,
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

/// Aligns with app suspendWaitHardCap (and stays above hub
/// `TURN_RESULT_TTL_MS` so the replay window is fully usable).
const Duration kPeerInflightTurnTtl = Duration(minutes: 30);

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

  // Remote user prompts the transcript has answered: an agent message exists
  // after the prompt's last occurrence.
  final lastUserIndexByContent = <String, int>{};
  var lastAgentIndex = -1;
  for (var i = 0; i < transcript.length; i++) {
    final e = transcript[i];
    if (e.role == 'user') {
      lastUserIndexByContent[e.content.trim()] = i;
    } else {
      lastAgentIndex = i;
    }
  }
  final answeredUserContents = <String>{
    for (final entry in lastUserIndexByContent.entries)
      if (entry.value < lastAgentIndex) entry.key,
  };

  // Local user rows being superseded by the remote transcript: content matches
  // a remote prompt that the remote has answered. Their ids anchor the local
  // agent replies of the same turn.
  final supersedingUserIds = <String>{};
  for (final row in rows) {
    if (row.id.isEmpty || row.id.startsWith('peerhist_')) continue;
    if (row.senderType != 'user') continue;
    if (remoteIds.contains(row.id) || preserveIds.contains(row.id)) continue;
    if (!answeredUserContents.contains(row.content.trim())) continue;
    final key = peerHistoryRoleContentKey('user', row.content);
    if (remoteRoleContentKeys.contains(key)) supersedingUserIds.add(row.id);
  }

  bool turnLinkedToSupersededPrompt(PeerHistorySyncLocalRow row) {
    final anchor = row.replyToId;
    return anchor != null && supersedingUserIds.contains(anchor);
  }

  final toDelete = <String>{};
  for (final row in rows) {
    if (row.id.isEmpty) continue;
    if (remoteIds.contains(row.id)) continue;
    if (preserveIds.contains(row.id)) continue;
    if (peerHistorySyncRowIsStreaming(row.metadataJson)) {
      final covered = row.content.isNotEmpty &&
          remoteAgentContents.any((c) => c.startsWith(row.content));
      if (!covered && !turnLinkedToSupersededPrompt(row)) continue;
      toDelete.add(row.id);
      continue;
    }
    if (!row.id.startsWith('peerhist_')) {
      final role = row.senderType == 'user' ? 'user' : 'agent';
      final key = peerHistoryRoleContentKey(role, row.content);
      if (!remoteRoleContentKeys.contains(key) &&
          !(role == 'agent' && turnLinkedToSupersededPrompt(row))) {
        continue;
      }
    }
    toDelete.add(row.id);
  }
  return toDelete;
}

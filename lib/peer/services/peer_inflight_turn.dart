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

/// Aligns with hub `TURN_RESULT_TTL_MS` / app [suspendWaitHardCap].
const Duration kPeerInflightTurnTtl = Duration(minutes: 25);

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

  const PeerHistorySyncLocalRow({
    required this.id,
    required this.senderType,
    required this.content,
    this.metadataJson,
  });
}

String peerHistoryRoleContentKey(String role, String content) => '$role\n$content';

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
///   transcript (a message the phone created that the agent has not
///   committed yet).
///
/// A `status: streaming` row outside [preserveIds] belongs to a dead turn
/// (process kill + resume lost/expired, etc.). Once the remote transcript
/// contains an agent message covering its content (prefix match), the orphan
/// must be deleted — otherwise it survives forever next to the `peerhist_*`
/// full message, showing "half reply + full reply" as two bubbles.
Set<String> localMessageIdsToDeleteOnPeerHistorySync({
  required Iterable<PeerHistorySyncLocalRow> localRows,
  required Set<String> remoteIds,
  required Set<String> remoteRoleContentKeys,
  required Set<String> preserveIds,
  /// Raw contents of the remote transcript's agent messages, used to decide
  /// whether an orphan streaming row is already covered by a fuller remote
  /// version.
  Iterable<String> remoteAgentContents = const [],
}) {
  final toDelete = <String>{};
  for (final row in localRows) {
    if (row.id.isEmpty) continue;
    if (remoteIds.contains(row.id)) continue;
    if (preserveIds.contains(row.id)) continue;
    if (peerHistorySyncRowIsStreaming(row.metadataJson)) {
      final covered = row.content.isNotEmpty &&
          remoteAgentContents.any((c) => c.startsWith(row.content));
      if (!covered) continue;
      toDelete.add(row.id);
      continue;
    }
    if (!row.id.startsWith('peerhist_')) {
      final role = row.senderType == 'user' ? 'user' : 'agent';
      final key = peerHistoryRoleContentKey(role, row.content);
      if (!remoteRoleContentKeys.contains(key)) continue;
    }
    toDelete.add(row.id);
  }
  return toDelete;
}

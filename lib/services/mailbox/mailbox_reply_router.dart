/// Destination channel for a mailbox reply.
///
/// Replies with a non-empty [groupId] only go to that group channel when it
/// exists — they never fall back to a DM. Missing group means skip (do not
/// ack). Replies without [groupId] go to [fallbackChannelId] when provided.
String? resolveMailboxReplyDestination({
  required String? groupId,
  required String? fallbackChannelId,
  required bool Function(String channelId) groupChannelExists,
}) {
  final gid = groupId?.trim() ?? '';
  if (gid.isNotEmpty) {
    return groupChannelExists(gid) ? gid : null;
  }
  final fallback = fallbackChannelId?.trim() ?? '';
  return fallback.isEmpty ? null : fallback;
}

/// Prefer payload `group_id` (sealed body) over the envelope field.
String mailboxReplyGroupId({
  required String replyGroupId,
  required Map<String, dynamic> payload,
}) {
  final fromPayload = payload['group_id']?.toString().trim() ?? '';
  if (fromPayload.isNotEmpty) return fromPayload;
  return replyGroupId.trim();
}

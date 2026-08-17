/// Save-plan for group turns collected via the channel mailbox.
///
/// When a member reply arrives through the mailbox poller, the group executor
/// must persist it under the same deterministic id (`inbox_<userMessageId>`)
/// that `ChatService.fetchMailboxReplies` computes, and carry the mailbox
/// provenance metadata that path uses for dedupe — otherwise a concurrent
/// push-driven fetch of the same reply inserts a second copy into the group.
library;

import '../../models/message.dart';

class GroupMailboxSavePlan {
  /// Metadata keys copied from the mailbox-collected reply. `status` is
  /// deliberately excluded: it carries left_message/pending semantics
  /// elsewhere.
  static const whitelistedMetadataKeys = [
    'from_mailbox',
    'mailbox_entry_id',
    'request_id',
    'session_id',
    'group_id',
  ];

  /// Deterministic id for the saved row: the mailbox reply's own id when the
  /// turn came through the mailbox, else the caller's freshly generated id.
  static String messageIdFor(Message? mailboxReply, String fallbackId) =>
      mailboxReply?.id ?? fallbackId;

  /// Merge mailbox provenance into [base] (mutated in place, returned for
  /// convenience). Existing keys such as trace_id are preserved.
  static Map<String, dynamic> mergeMetadata(
    Map<String, dynamic> base,
    Message? mailboxReply,
  ) {
    final src = mailboxReply?.metadata;
    if (src == null) return base;
    for (final key in whitelistedMetadataKeys) {
      final value = src[key];
      if (value != null) base[key] = value;
    }
    return base;
  }
}

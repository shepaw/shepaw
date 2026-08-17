/// Turn-level ownership for channel mailbox replies.
///
/// When an agent is busy, `AgentMessagingService.leaveMailboxAndCollect`
/// deposits a sealed message and runs a `MailboxInboxPoller` to await the
/// reply. The *same* reply push also wakes the controller's inbox listener,
/// which fetches and acks the same entries via `ChatService.fetchMailboxReplies`
/// — without coordination, one side acks first and the poller times out
/// (member wrongly marked failed), or both insert the reply (duplicate bubble).
///
/// The claiming side (poller owner) registers the turn here; fetch-based
/// consumers skip claimed replies *without acking*, leaving them for the
/// poller. Claims are process-local and released when the turn ends — a
/// timeout releases the claim so a later fetch can still deliver the reply.
library;

import 'channel_mailbox_service.dart';

class _TurnKey {
  const _TurnKey(this.requestId, this.userMessageId);

  final String requestId;
  final String userMessageId;

  @override
  bool operator ==(Object other) =>
      other is _TurnKey &&
      other.requestId == requestId &&
      other.userMessageId == userMessageId;

  @override
  int get hashCode => Object.hash(requestId, userMessageId);
}

class MailboxTurnClaims {
  /// Instances are independent; production code uses [instance], tests can
  /// construct isolated ones.
  MailboxTurnClaims();

  static final MailboxTurnClaims instance = MailboxTurnClaims();

  final Map<String, Set<_TurnKey>> _claimsByAgent = {};

  /// Claim a mailbox turn. [requestId] and [userMessageId] must be non-empty.
  void claim(String agentId, String requestId, String userMessageId) {
    assert(requestId.isNotEmpty && userMessageId.isNotEmpty);
    _claimsByAgent.putIfAbsent(agentId, () => {}).add(
          _TurnKey(requestId, userMessageId),
        );
  }

  /// Release a previously claimed turn. No-op for unknown claims.
  void release(String agentId, String requestId, String userMessageId) {
    final set = _claimsByAgent[agentId];
    if (set == null) return;
    set.remove(_TurnKey(requestId, userMessageId));
    if (set.isEmpty) _claimsByAgent.remove(agentId);
  }

  /// Whether an active turn for [agentId] owns the reply identified by the
  /// envelope fields [requestId] / [replyTo] (matches the poller's
  /// `_matchesTurn` semantics: requestId equal, or replyTo == userMessageId).
  /// Empty candidates never match.
  bool isClaimed(
    String agentId, {
    required String requestId,
    required String replyTo,
  }) {
    if (requestId.isEmpty && replyTo.isEmpty) return false;
    final set = _claimsByAgent[agentId];
    if (set == null) return false;
    for (final key in set) {
      if (requestId.isNotEmpty && key.requestId == requestId) return true;
      if (replyTo.isNotEmpty && key.userMessageId == replyTo) return true;
    }
    return false;
  }
}

/// What `ChatService.fetchMailboxReplies` should do with a reply, decided
/// before any decryption or ack.
enum MailboxReplyAction {
  /// An active poller owns this turn — skip and do NOT ack (leave for poller).
  claimedSkip,

  /// Envelope-level stream chunk with no active poller — orphan; ack + drop.
  orphanStreamAck,

  /// No claim, not an orphan chunk — proceed to decrypt and deliver.
  process,
}

/// Pure prefilter for the fetchMailboxReplies loop. Must run as the FIRST
/// statement per reply: checking claims before the orphan-stream ack branch
/// prevents a push-driven fetch from acking away stream chunks that an active
/// poller is still consuming.
class MailboxReplyPrefilter {
  static MailboxReplyAction classify(
    MailboxReply reply,
    String acpAgentId,
    MailboxTurnClaims claims,
  ) {
    if (claims.isClaimed(
      acpAgentId,
      requestId: reply.requestId,
      replyTo: reply.replyTo,
    )) {
      return MailboxReplyAction.claimedSkip;
    }
    if (reply.kind == 'stream') return MailboxReplyAction.orphanStreamAck;
    return MailboxReplyAction.process;
  }
}

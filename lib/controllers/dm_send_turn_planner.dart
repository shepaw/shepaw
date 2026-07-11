import '../models/message.dart';
import 'chat_streaming_text.dart';

/// Parsed `onRequestHistory` / pending-history payload.
class HistoryRequestInfo {
  final String reason;
  final String requestId;
  final int requestedCount;

  const HistoryRequestInfo({
    required this.reason,
    required this.requestId,
    required this.requestedCount,
  });

  factory HistoryRequestInfo.fromMap(Map<String, dynamic> data) {
    return HistoryRequestInfo(
      reason: data['reason'] as String? ?? 'Agent needs more context',
      requestId: data['request_id'] as String? ?? '',
      requestedCount: data['requested_count'] as int? ?? 40,
    );
  }
}

/// Outcome of one history-supplement round.
enum HistorySupplementRoundAction {
  /// Service returned null — no more history.
  noMoreHistory,

  /// Agent asked for still more history.
  needMoreHistory,

  /// Supplement delivered; agent can re-answer.
  reanswerReady,
}

class HistorySupplementRoundDecision {
  final HistorySupplementRoundAction action;
  final int actualSentCount;
  final String? nextReason;
  final int? nextRequestedCount;
  final bool deleteEmptySupplementMessage;

  const HistorySupplementRoundDecision({
    required this.action,
    this.actualSentCount = 0,
    this.nextReason,
    this.nextRequestedCount,
    this.deleteEmptySupplementMessage = false,
  });
}

/// Post-send decisions for DM async-confirmation vs sync turns.
class DmAsyncTurnDecision {
  /// Hook ActiveTask.onTaskFinished and skip finally cleanup.
  final bool awaitingAsyncTask;

  /// Show `chat_responseError` when agentResponse is null.
  final bool showNullResponseError;

  /// Call loadMessages() before leaving processMessage.
  final bool loadMessagesNow;

  const DmAsyncTurnDecision({
    required this.awaitingAsyncTask,
    required this.showNullResponseError,
    required this.loadMessagesNow,
  });
}

/// Pure planners for DM [ChatController.processMessage] turn bookkeeping.
class DmSendTurnPlanner {
  DmSendTurnPlanner._();

  static const maxHistorySupplementRounds = 3;

  /// Optimistic user + streaming agent bubbles shown before the network round-trip.
  static ({Message user, Message streaming}) buildOptimisticPair({
    required String content,
    required String userId,
    required String userName,
    required String agentId,
    required String agentName,
    String? replyToId,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final user = Message(
      id: 'temp_user_$now',
      content: content,
      timestampMs: now,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      to: MessageFrom(id: agentId, type: 'agent', name: agentName),
      type: MessageType.text,
      replyTo: replyToId,
    );
    final streaming = ChatStreamingText.placeholder(
      id: 'streaming_$now',
      from: MessageFrom(id: agentId, type: 'agent', name: agentName),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      timestampMs: now + 1,
    );
    return (user: user, streaming: streaming);
  }

  static HistorySupplementRoundDecision evaluateSupplementRound({
    required bool supplementIsNull,
    required int actualSentCount,
    required String messageContent,
    Map<String, dynamic>? pendingHistoryRequest,
  }) {
    if (supplementIsNull) {
      return const HistorySupplementRoundDecision(
        action: HistorySupplementRoundAction.noMoreHistory,
      );
    }
    if (pendingHistoryRequest != null) {
      final next = HistoryRequestInfo.fromMap(pendingHistoryRequest);
      return HistorySupplementRoundDecision(
        action: HistorySupplementRoundAction.needMoreHistory,
        actualSentCount: actualSentCount,
        nextReason: next.reason,
        nextRequestedCount: next.requestedCount,
        deleteEmptySupplementMessage: messageContent.isEmpty,
      );
    }
    return HistorySupplementRoundDecision(
      action: HistorySupplementRoundAction.reanswerReady,
      actualSentCount: actualSentCount,
    );
  }

  /// Decide async hook / null-response snackbar / immediate reload after send.
  static DmAsyncTurnDecision afterAgentSend({
    required bool supportsAsyncConfirmation,
    required bool hasChannel,
    required bool hasActiveTask,
    required bool handledHistorySupplement,
    required bool agentResponseIsNull,
  }) {
    final awaiting = supportsAsyncConfirmation && hasChannel && hasActiveTask;
    final showNullError = !handledHistorySupplement &&
        agentResponseIsNull &&
        !supportsAsyncConfirmation;
    return DmAsyncTurnDecision(
      awaitingAsyncTask: awaiting,
      showNullResponseError: showNullError,
      loadMessagesNow: !awaiting,
    );
  }
}

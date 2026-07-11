import '../../models/message.dart';

/// Pure helpers for keeping in-chat plan_approval cards in sync with the
/// floating workflow panel / ChatService Completer.
class WorkflowPlanApprovalSync {
  WorkflowPlanApprovalSync._();

  /// Prefer the card tagged with [workflowId]; else the latest unanswered card.
  static Message? findPlanApprovalMessage({
    required Iterable<Message> messages,
    required String workflowId,
  }) {
    Message? fallback;
    for (final msg in messages.toList().reversed) {
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null) continue;
      if (plan['_workflowId'] == workflowId) {
        return msg;
      }
      if (plan['_approved'] == null &&
          msg.metadata?['plan_approval_responded'] == null) {
        fallback ??= msg;
      }
    }
    return fallback;
  }

  static Map<String, dynamic> buildRespondedPatch({
    required bool approved,
    String? feedback,
  }) =>
      {
        'approved': approved,
        if (feedback != null && feedback.isNotEmpty) 'feedback': feedback,
      };

  static Map<String, dynamic> mergeApprovedFlag(
    Map<String, dynamic> existingPlan,
    bool approved,
  ) {
    final merged = Map<String, dynamic>.from(existingPlan);
    merged['_approved'] = approved;
    return merged;
  }

  /// Payload for [ChatService.completePlanApproval].
  static Map<String, dynamic> buildCompleterPayload({
    required bool approved,
    String? feedback,
    List<String>? skippedTaskIds,
  }) =>
      {
        'approved': approved,
        if (feedback != null && feedback.isNotEmpty) 'feedback': feedback,
        if (skippedTaskIds != null && skippedTaskIds.isNotEmpty)
          'skipped_task_ids': skippedTaskIds,
      };
}

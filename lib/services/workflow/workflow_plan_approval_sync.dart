import '../../models/message.dart';

/// User decision on a workflow plan, kept until it can be written to a
/// persisted (non-streaming) message row.
class WorkflowPlanApprovalResponse {
  final bool approved;
  final String? feedback;

  const WorkflowPlanApprovalResponse({
    required this.approved,
    this.feedback,
  });
}

/// Pure helpers for keeping in-chat plan_approval cards in sync with the
/// floating workflow panel / ChatService Completer.
class WorkflowPlanApprovalSync {
  WorkflowPlanApprovalSync._();

  /// Streaming / temp host bubbles that are not durable DB rows.
  static bool isEphemeralHostId(String id) =>
      id.startsWith('streaming_') ||
      id.startsWith('group_streaming_') ||
      id.startsWith('wf_streaming_') ||
      id.startsWith('group_peer_approval_') ||
      id.startsWith('temp_user_');

  /// Prefer the card tagged with [workflowId]; else the latest unanswered card.
  ///
  /// When [preferPersisted] is true, skip ephemeral streaming hosts so callers
  /// can write metadata onto the durable message id after a DM turn saves.
  static Message? findPlanApprovalMessage({
    required Iterable<Message> messages,
    required String workflowId,
    bool preferPersisted = false,
  }) {
    Message? fallback;
    Message? ephemeralMatch;
    for (final msg in messages.toList().reversed) {
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null) continue;
      if (plan['_workflowId'] == workflowId) {
        if (preferPersisted && isEphemeralHostId(msg.id)) {
          ephemeralMatch ??= msg;
          continue;
        }
        return msg;
      }
      if (plan['_approved'] == null &&
          msg.metadata?['plan_approval_responded'] == null) {
        if (preferPersisted && isEphemeralHostId(msg.id)) continue;
        fallback ??= msg;
      }
    }
    if (preferPersisted) return fallback;
    return ephemeralMatch ?? fallback;
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

  /// Merge respond flags into a full message metadata map (for DB persist).
  static Map<String, dynamic> applyResponseToMetadata(
    Map<String, dynamic>? existingMetadata, {
    required bool approved,
    String? feedback,
  }) {
    final meta = Map<String, dynamic>.from(existingMetadata ?? {});
    meta['plan_approval_responded'] = buildRespondedPatch(
      approved: approved,
      feedback: feedback,
    );
    final plan = meta['plan_approval'];
    if (plan is Map) {
      meta['plan_approval'] = mergeApprovedFlag(
        Map<String, dynamic>.from(plan),
        approved,
      );
    }
    return meta;
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

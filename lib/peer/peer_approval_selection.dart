import '../models/workflow_models.dart';

/// Pure helpers for merging / superseding peer tool-approval selections.
class PeerApprovalSelection {
  PeerApprovalSelection._();

  /// Merge a resolved approval onto [data] (mutates in place).
  ///
  /// Used by group executor final save and by UI optimistic updates.
  static void applySelection(
    Map<String, dynamic> data,
    Map<String, dynamic> responseData, {
    int? selectedAtMs,
  }) {
    final selectedId = responseData['selected_action_id'] as String?;
    if (selectedId == null || selectedId.isEmpty) return;
    data['selected_action_id'] = selectedId;
    final label = responseData['selected_action_label'] as String?;
    if (label != null && label.isNotEmpty) {
      data['selected_action_label'] = label;
    }
    data['selected_at'] =
        responseData['selected_at'] ??
        selectedAtMs ??
        DateTime.now().millisecondsSinceEpoch;
  }

  /// Whether a newer approval for the same workflow step should replace [prev].
  static bool shouldSupersede({
    required WorkflowPeerApprovalPending? prev,
    required String newStepId,
    required String? newConfirmationId,
  }) {
    if (prev == null) return false;
    if (prev.stepId != newStepId) return false;
    final prevId = prev.confirmationId;
    if (prevId == null || prevId.isEmpty) return false;
    if (newConfirmationId == null || newConfirmationId.isEmpty) return false;
    return prevId != newConfirmationId;
  }

  /// Completer payload that auto-denies a superseded in-flight approval.
  ///
  /// Still submitted to the peer hub so [openApprovals] can drop, but
  /// consumers must skip writing this into final message metadata when
  /// `_superseded` is true.
  static Map<String, dynamic> buildSupersededDenyResponse() => {
        'selected_action_id': 'deny',
        'selected_action_label': '被后续审批取代',
        '_approval_submitted': false,
        '_superseded': true,
      };

  /// Parse `_approvalRisk` from hub / workflow metadata.
  static PeerApprovalRisk parseRisk(Map<String, dynamic> data) {
    final raw = data['_approvalRisk'] as String?;
    return raw == 'low' ? PeerApprovalRisk.low : PeerApprovalRisk.high;
  }

  /// Whether the panel banner for [pending] should clear after [confirmationId]
  /// completes (avoid clearing when a newer sequential approval replaced it).
  static bool shouldClearPendingAfterCompletion({
    required WorkflowPeerApprovalPending? pending,
    required String? completedConfirmationId,
    required String? completedStepId,
  }) {
    if (pending == null) return false;
    if (completedConfirmationId != null && completedConfirmationId.isNotEmpty) {
      // Exact match only — a newer sequential approval keeps the banner.
      return pending.confirmationId == completedConfirmationId;
    }
    return completedStepId != null && pending.stepId == completedStepId;
  }
}
import '../../models/message.dart';
import '../../models/workflow_models.dart';
import '../../models/workflow_pending_approval.dart';
import '../../peer/peer_approval_selection.dart';

/// Pure helpers for recovering in-flight peer approvals on channel load.
class WorkflowPendingApprovalPicker {
  WorkflowPendingApprovalPicker._();

  /// Prefer a pending row matching [activeWorkflowId], else the first row.
  static WorkflowPendingApproval? pickDbRecord({
    required List<WorkflowPendingApproval> dbPending,
    required String? activeWorkflowId,
  }) {
    if (dbPending.isEmpty) return null;
    if (activeWorkflowId != null) {
      for (final p in dbPending) {
        if (p.workflowId == activeWorkflowId) return p;
      }
    }
    return dbPending.first;
  }

  /// Scan recent messages for an unanswered workflow peer-approval card.
  static WorkflowPeerApprovalPending? findInMessages({
    required String activeWorkflowId,
    required Iterable<Message> messages,
  }) {
    for (final msg in messages.toList().reversed) {
      final ac = msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
      if (ac == null || ac['_workflowPeerApproval'] != true) continue;
      if (ac['selected_action_id'] != null) continue;
      final wfId = ac['_workflowId'] as String?;
      if (wfId != null && wfId != activeWorkflowId) continue;
      final stepId = ac['_workflowStepId'] as String?;
      if (stepId == null) continue;
      return WorkflowPeerApprovalPending(
        workflowId: activeWorkflowId,
        stepId: stepId,
        agentId: msg.from.id,
        agentName: msg.from.name,
        messageId: msg.id,
        prompt: ac['prompt'] as String?,
        risk: PeerApprovalSelection.parseRisk(ac),
        confirmationId: ac['confirmation_id'] as String?,
        approvalData: ac,
        execChannelId: ac['_workflowExecChannelId'] as String?,
      );
    }
    return null;
  }
}

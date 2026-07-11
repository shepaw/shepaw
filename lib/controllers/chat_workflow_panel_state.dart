import '../models/workflow_models.dart';

/// UI-facing state for the floating workflow progress panel.
///
/// Owns active workflow id, dismiss/reopen, and the in-flight peer approval
/// banner. Execution / DB / Completer wiring stays on [ChatController].
class ChatWorkflowPanelState {
  String? activeWorkflowId;
  bool dismissed = false;
  WorkflowPeerApprovalPending? peerApprovalPending;

  bool get showProgressPanel =>
      activeWorkflowId != null && !dismissed;

  bool get needsPanelAttention =>
      activeWorkflowId != null && dismissed;

  void setActiveWorkflowId(String? id) {
    activeWorkflowId = id;
    if (id != null) dismissed = false;
    if (id == null) peerApprovalPending = null;
  }

  void setPeerApprovalPending(WorkflowPeerApprovalPending? pending) {
    peerApprovalPending = pending;
    if (pending != null) dismissed = false;
  }

  void dismiss() => dismissed = true;

  void reopen() => dismissed = false;

  /// Clear peer banner + streaming-related panel state when execution ends
  /// or the user cancels (active workflow id cleared by caller when needed).
  void clearPeerApproval() => peerApprovalPending = null;
}

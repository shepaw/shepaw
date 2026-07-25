import '../models/workflow_models.dart';
import '../peer/peer_approval_selection.dart';
import '../services/chat_service.dart';
import '../services/logger_service.dart';
import 'chat_workflow_panel_state.dart';

/// Owns workflow panel + local execution bookkeeping for [ChatController].
///
/// Streaming UI mutations and DB restore I/O stay on the controller; this class
/// holds the mutable execution handles (cancel token / streaming ids) and the
/// [ChatWorkflowPanelState] so controller methods stay thinner.
class ChatWorkflowCoordinator {
  ChatWorkflowCoordinator();

  final ChatWorkflowPanelState panel = ChatWorkflowPanelState();

  /// Cancellation token for the controller-started execution loop.
  WorkflowCancellationToken? cancelToken;

  /// Workflow step streaming placeholders keyed by agent id.
  final Map<String, String> streamingIds = {};
  final Map<String, String> streamingContents = {};

  String? get activeWorkflowId => panel.activeWorkflowId;

  bool get hasLocalExecution => cancelToken != null;

  bool get showProgressPanel => panel.showProgressPanel;

  bool get needsPanelAttention => panel.needsPanelAttention;

  WorkflowPeerApprovalPending? get peerApprovalPending =>
      panel.peerApprovalPending;

  void setActiveWorkflowId(String? id) => panel.setActiveWorkflowId(id);

  void setPeerApprovalPending(WorkflowPeerApprovalPending? pending) =>
      panel.setPeerApprovalPending(pending);

  void dismissPanel() => panel.dismiss();

  void reopenPanel() => panel.reopen();

  void clearPeerApproval() => panel.clearPeerApproval();

  /// Key used in `pendingGroupInteractions` for a step interaction.
  ///
  /// Peer action confirmations are keyed by confirmation_id so sequential
  /// approvals on the same agent/message do not overwrite each other.
  static String interactionPendingKey({
    required String interactionType,
    required Map<String, dynamic> data,
    required String? sid,
    required String agentId,
  }) {
    final confirmationId = data['confirmation_id'] as String?;
    if (interactionType == 'action_confirmation' &&
        confirmationId != null &&
        confirmationId.isNotEmpty) {
      return confirmationId;
    }
    return sid ?? agentId;
  }

  /// Register a workflow peer-approval on the progress panel.
  ///
  /// Returns the stale confirmation id that should be auto-denied when a newer
  /// sequential approval supersedes the previous one; otherwise null.
  String? registerWorkflowPeerApproval({
    required String agentId,
    required String agentName,
    required String? messageId,
    required Map<String, dynamic> data,
  }) {
    final activeId = activeWorkflowId;
    if (activeId == null) return null;
    if (data['_workflowPeerApproval'] != true) return null;
    final stepId = data['_workflowStepId'] as String?;
    if (stepId == null) return null;

    final confirmationId = data['confirmation_id'] as String?;
    final prev = peerApprovalPending;
    String? staleConfirmationId;
    if (PeerApprovalSelection.shouldSupersede(
      prev: prev,
      newStepId: stepId,
      newConfirmationId: confirmationId,
    )) {
      staleConfirmationId = prev!.confirmationId;
    }

    setPeerApprovalPending(WorkflowPeerApprovalPending(
      workflowId: activeId,
      stepId: stepId,
      agentId: agentId,
      agentName: agentName,
      messageId: messageId,
      prompt: data['prompt'] as String?,
      risk: PeerApprovalSelection.parseRisk(data),
      confirmationId: confirmationId,
      approvalData: Map<String, dynamic>.from(data),
      execChannelId: data['_workflowExecChannelId'] as String?,
    ));
    return staleConfirmationId;
  }

  /// Clear the panel banner after an approval Completer settles, unless a
  /// newer sequential approval already replaced it.
  bool clearPeerApprovalIfCurrent({
    required String? completedConfirmationId,
    required String? completedStepId,
  }) {
    if (!PeerApprovalSelection.shouldClearPendingAfterCompletion(
      pending: peerApprovalPending,
      completedConfirmationId: completedConfirmationId,
      completedStepId: completedStepId,
    )) {
      return false;
    }
    clearPeerApproval();
    return true;
  }

  /// Start a local cancel token if ChatService is not already executing.
  ///
  /// Returns null when execution should be skipped (already running elsewhere
  /// or a local token already exists). Caller should reattach UI when
  /// [ChatService.isWorkflowExecuting] is true.
  WorkflowCancellationToken? takeCancelTokenForNewExecution({
    required ChatService chatService,
    required String workflowId,
  }) {
    if (chatService.isWorkflowExecuting(workflowId)) return null;
    if (cancelToken != null) return null;
    final token = WorkflowCancellationToken();
    cancelToken = token;
    return token;
  }

  /// Adopt the cancel token from an existing ChatService execution.
  void adoptCancelToken(WorkflowCancellationToken? token) {
    cancelToken = token;
  }

  void clearStreaming() {
    streamingIds.clear();
    streamingContents.clear();
  }

  /// Called when the ChatService execution loop finishes.
  void onExecutionFinished() {
    clearStreaming();
    cancelToken = null;
    panel.clearPeerApproval();
  }

  /// Local teardown for user cancel (DB / Completer cleanup stays on caller).
  void prepareLocalCancel() {
    cancelToken?.cancel();
    cancelToken = null;
    clearStreaming();
    panel.clearPeerApproval();
    panel.setActiveWorkflowId(null);
  }

  /// Detach on controller dispose — keep ChatService loop alive.
  void detachOnDispose() {
    cancelToken = null;
  }

  String? streamingIdFor(String agentId) => streamingIds[agentId];

  void trackAgentStart(String agentId, String streamingMessageId) {
    streamingIds[agentId] = streamingMessageId;
    streamingContents[agentId] = '';
  }

  String appendStreamChunk(String agentId, String chunk) {
    streamingContents[agentId] = (streamingContents[agentId] ?? '') + chunk;
    return streamingContents[agentId]!;
  }

  String? removeAgentStreaming(String agentId) {
    streamingContents.remove(agentId);
    return streamingIds.remove(agentId);
  }

  /// Apply a plan approve/reject decision after the in-chat card has been synced.
  ///
  /// [startExecution] starts (or resumes) step execution for an approved plan.
  /// [sendRejectionFeedback] posts admin re-plan feedback when the user rejects
  /// with comments.
  Future<void> applyPlanDecision({
    required bool approved,
    required String workflowId,
    required Future<void> Function(String workflowId) startWorkflow,
    required Future<void> Function(String workflowId) cancelWorkflow,
    required Future<void> Function(String workflowId) startExecution,
    Future<void> Function(String feedbackMessage)? sendRejectionFeedback,
    String? feedback,
    void Function()? notify,
  }) async {
    if (approved) {
      await startWorkflow(workflowId);
      notify?.call();
      await startExecution(workflowId);
      return;
    }

    await cancelWorkflow(workflowId);
    setActiveWorkflowId(null);
    notify?.call();

    if (feedback == null || feedback.isEmpty || sendRejectionFeedback == null) {
      return;
    }
    final feedbackMessage = '用户拒绝了工作流计划并提出修改意见: $feedback';
    try {
      await sendRejectionFeedback(feedbackMessage);
    } catch (e) {
      LoggerService().error(
        'Failed to send workflow rejection feedback',
        tag: 'ChatWorkflowCoordinator',
        error: e,
      );
      rethrow;
    }
  }
}

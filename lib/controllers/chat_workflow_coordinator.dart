import '../models/workflow_models.dart';
import '../services/chat_service.dart';
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
}

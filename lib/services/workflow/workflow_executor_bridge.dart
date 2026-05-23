import '../../models/workflow_models.dart';
import '../logger_service.dart';
import 'workflow_service.dart';

/// Bridges FlowExecutor lifecycle events to WorkflowService persistence.
///
/// This adapter is injected into FlowExecutor (optional) to report
/// step start/complete/fail events so they are persisted in real time.
class WorkflowExecutorBridge {
  final WorkflowService _workflowService;
  final String workflowExecutionId;

  /// Maps "stageIndex:stepIndex" → WorkflowStepExecution.id for quick lookup.
  final Map<String, String> _stepKeyToId;

  WorkflowExecutorBridge({
    required WorkflowService workflowService,
    required this.workflowExecutionId,
    required List<WorkflowStepExecution> steps,
  })  : _workflowService = workflowService,
        _stepKeyToId = _buildStepMap(steps);

  static Map<String, String> _buildStepMap(List<WorkflowStepExecution> steps) {
    final map = <String, String>{};
    for (final step in steps) {
      map['${step.stageIndex}:${step.stepIndex}'] = step.id;
    }
    return map;
  }

  String? _resolveStepId(int stageIndex, int stepIndex) {
    return _stepKeyToId['$stageIndex:$stepIndex'];
  }

  // ---------------------------------------------------------------------------
  // Step lifecycle callbacks (called by FlowExecutor)
  // ---------------------------------------------------------------------------

  /// Called when a step begins execution.
  Future<void> onStepStart(int stageIndex, int stepIndex) async {
    final stepId = _resolveStepId(stageIndex, stepIndex);
    if (stepId == null) {
      LoggerService().warning(
        'WorkflowExecutorBridge: no step found for $stageIndex:$stepIndex',
        tag: 'WorkflowBridge',
      );
      return;
    }
    await _workflowService.startStep(stepId);
  }

  /// Called when a step completes successfully.
  Future<void> onStepComplete(int stageIndex, int stepIndex, {String? outputSummary}) async {
    final stepId = _resolveStepId(stageIndex, stepIndex);
    if (stepId == null) return;
    await _workflowService.completeStep(stepId, outputSummary: outputSummary);
  }

  /// Called when a step fails.
  Future<void> onStepFail(int stageIndex, int stepIndex, String error) async {
    final stepId = _resolveStepId(stageIndex, stepIndex);
    if (stepId == null) return;
    await _workflowService.failStep(stepId, error);
  }

  /// Called when a step is skipped.
  Future<void> onStepSkip(int stageIndex, int stepIndex) async {
    final stepId = _resolveStepId(stageIndex, stepIndex);
    if (stepId == null) return;
    await _workflowService.skipStep(stepId);
  }

  // ---------------------------------------------------------------------------
  // Workflow lifecycle callbacks
  // ---------------------------------------------------------------------------

  /// Called when the entire workflow completes successfully.
  Future<void> onFlowComplete({String? summary}) async {
    await _workflowService.completeWorkflow(workflowExecutionId, summary: summary);
  }

  /// Called when the entire workflow fails.
  Future<void> onFlowFail(String error) async {
    await _workflowService.failWorkflow(workflowExecutionId, error);
  }

  /// Called when the workflow is cancelled/aborted.
  Future<void> onFlowCancel() async {
    await _workflowService.cancelWorkflow(workflowExecutionId);
  }
}

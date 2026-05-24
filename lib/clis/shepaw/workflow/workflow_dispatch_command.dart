import '../../cli_base.dart';
import '../../../models/workflow_models.dart';
import '../../../services/workflow/workflow_service.dart';
import '../../../services/local_database_service.dart';

/// 委派指定阶段的步骤给对应 Agent 执行。
///
/// 用法：
///   shepaw workflow dispatch --workflow_id <id> --stage_index <n>
///
/// 系统行为：
/// - 并行调用阶段内所有 Agent（通过 processGroupAgent）
/// - 等待全部完成后返回结果
/// - 自动更新各步骤状态
///
/// 注意：此命令是阻塞式的，直到阶段内所有步骤完成才返回。
class WorkflowDispatchCommand extends CliCommand {
  /// Per-channel step execution callbacks.
  /// Keyed by channelId to prevent cross-channel contamination (C1 fix).
  /// Set by GroupAgentExecutor before each CLI invocation.
  static final Map<String, Future<String> Function(String agentName, String instruction, String channelId)>
      executeStepFnMap = {};

  /// Convenience setter — sets for a specific channel.
  static void setExecuteStepFn(
    String channelId,
    Future<String> Function(String agentName, String instruction, String channelId) fn,
  ) {
    executeStepFnMap[channelId] = fn;
  }

  /// Convenience removal — clears for a specific channel.
  static void clearExecuteStepFn(String channelId) {
    executeStepFnMap.remove(channelId);
  }

  @override
  String get name => 'dispatch';

  @override
  String get description =>
      'Dispatch a workflow stage — execute all steps in parallel';

  @override
  String get usage =>
      'shepaw workflow dispatch --workflow_id <id> --stage_index 0';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final workflowId = flags['workflow_id'];
    final stageIndexStr = flags['stage_index'];

    if (workflowId == null || workflowId.isEmpty) {
      return {'error': 'Missing required flag: --workflow_id'};
    }
    if (stageIndexStr == null) {
      return {'error': 'Missing required flag: --stage_index'};
    }

    final stageIndex = int.tryParse(stageIndexStr);
    if (stageIndex == null || stageIndex < 0) {
      return {'error': 'Invalid --stage_index: must be a non-negative integer'};
    }

    final workflowService = WorkflowService.instance;
    final workflow =
        await workflowService.getWorkflowExecutionWithSteps(workflowId);

    if (workflow == null) {
      return {'error': 'Workflow not found: $workflowId'};
    }

    if (workflow.status != WorkflowStatus.running) {
      return {
        'error': 'Workflow is not in running state (current: ${workflow.status.label})',
      };
    }

    // Get steps for the specified stage
    final stageSteps =
        workflow.steps.where((s) => s.stageIndex == stageIndex).toList();

    if (stageSteps.isEmpty) {
      return {
        'error': 'No steps found for stage_index $stageIndex',
        'available_stages': _getAvailableStages(workflow),
      };
    }

    final channelId = workflow.channelId;

    // Check if executeStepFn is set for this channel
    final executeStepFn = executeStepFnMap[channelId];
    if (executeStepFn == null) {
      return {
        'error':
            'Step execution is not available. Ensure this is called in a group chat context.',
      };
    }

    final results = <Map<String, dynamic>>[];

    // Execute steps in parallel
    final futures = stageSteps
        .where((s) => s.status != StepExecutionStatus.skipped)
        .map((step) async {
      await workflowService.startStep(step.id);

      try {
        final output = await executeStepFn(
          step.agentName,
          step.instruction,
          channelId,
        );
        await workflowService.completeStep(step.id, outputSummary: output);
        return {
          'agent': step.agentName,
          'step_index': step.stepIndex,
          'status': 'completed',
          'output_summary': output.length > 200
              ? '${output.substring(0, 197)}...'
              : output,
        };
      } catch (e) {
        await workflowService.failStep(step.id, e.toString());
        return {
          'agent': step.agentName,
          'step_index': step.stepIndex,
          'status': 'failed',
          'error': e.toString(),
        };
      }
    });

    results.addAll(await Future.wait(futures));

    // Add skipped steps to results
    for (final step in stageSteps.where(
        (s) => s.status == StepExecutionStatus.skipped)) {
      results.add({
        'agent': step.agentName,
        'step_index': step.stepIndex,
        'status': 'skipped',
      });
    }

    // Sort by step_index
    results.sort((a, b) =>
        (a['step_index'] as int).compareTo(b['step_index'] as int));

    final hasFailures = results.any((r) => r['status'] == 'failed');
    final stageName = stageSteps.first.stageName.isNotEmpty
        ? stageSteps.first.stageName
        : '阶段 ${stageIndex + 1}';

    return {
      'workflow_id': workflowId,
      'stage_index': stageIndex,
      'stage_name': stageName,
      'status': hasFailures ? 'has_failures' : 'completed',
      'results': results,
      'message': hasFailures
          ? '阶段 "$stageName" 执行完毕，部分步骤失败。请审视结果后决定下一步。'
          : '阶段 "$stageName" 全部步骤执行成功。',
    };
  }

  List<Map<String, dynamic>> _getAvailableStages(WorkflowExecution workflow) {
    final stageMap = <int, String>{};
    for (final step in workflow.steps) {
      stageMap.putIfAbsent(step.stageIndex,
          () => step.stageName.isNotEmpty ? step.stageName : '阶段 ${step.stageIndex + 1}');
    }
    return stageMap.entries
        .map((e) => {'stage_index': e.key, 'label': e.value})
        .toList();
  }
}

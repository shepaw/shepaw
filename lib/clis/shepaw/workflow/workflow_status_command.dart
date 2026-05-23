import '../../cli_base.dart';
import '../../../models/workflow_models.dart';
import '../../../services/workflow/workflow_service.dart';
import '../../../services/local_database_service.dart';
import 'workflow_namespace.dart';

/// 查看工作流当前执行状态。
///
/// 用法：
///   shepaw workflow status --workflow_id <id>
///   shepaw workflow status   (显示当前频道活跃的工作流)
class WorkflowStatusCommand extends CliCommand {
  @override
  String get name => 'status';

  @override
  String get description => 'View current workflow execution status';

  @override
  String get usage => 'shepaw workflow status [--workflow_id <id>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final workflowService = WorkflowService(db: LocalDatabaseService());
    final workflowId = flags['workflow_id'];

    WorkflowExecution? workflow;

    if (workflowId != null && workflowId.isNotEmpty) {
      workflow =
          await workflowService.getWorkflowExecutionWithSteps(workflowId);
    } else {
      // Try to get active workflow for current channel
      final channelId = WorkflowNamespace.instance.channelId;
      if (channelId != null) {
        workflow = await workflowService.getActiveWorkflow(channelId);
      }
    }

    if (workflow == null) {
      return {
        'status': 'no_active_workflow',
        'message': '当前没有活跃的工作流。',
      };
    }

    // Build stages info
    final stageMap = <int, List<WorkflowStepExecution>>{};
    final stageNames = <int, String>{};
    for (final step in workflow.steps) {
      stageMap.putIfAbsent(step.stageIndex, () => []).add(step);
      if (step.stageName.isNotEmpty) {
        stageNames[step.stageIndex] = step.stageName;
      }
    }

    final stages = stageMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final stagesInfo = stages.map((entry) {
      final idx = entry.key;
      final steps = entry.value;
      final completed = steps
          .where((s) =>
              s.status == StepExecutionStatus.completed ||
              s.status == StepExecutionStatus.skipped)
          .length;

      return {
        'stage_index': idx,
        'label': stageNames[idx] ?? '阶段 ${idx + 1}',
        'progress': '$completed/${steps.length}',
        'steps': steps
            .map((s) => {
                  'agent': s.agentName,
                  'instruction': s.instruction.length > 80
                      ? '${s.instruction.substring(0, 77)}...'
                      : s.instruction,
                  'status': s.status.label,
                })
            .toList(),
      };
    }).toList();

    return {
      'workflow_id': workflow.id,
      'title': workflow.title,
      'status': workflow.status.label,
      'progress': '${workflow.completedSteps}/${workflow.totalSteps} 步骤完成',
      'duration': workflow.durationLabel,
      'stages': stagesInfo,
    };
  }
}

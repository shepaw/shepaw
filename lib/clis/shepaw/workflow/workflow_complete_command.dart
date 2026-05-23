import '../../cli_base.dart';
import '../../../services/workflow/workflow_service.dart';
import '../../../services/local_database_service.dart';

/// 标记工作流执行成功完成。
///
/// 用法：
///   shepaw workflow complete --workflow_id <id> [--summary "完成摘要"]
class WorkflowCompleteCommand extends CliCommand {
  @override
  String get name => 'complete';

  @override
  String get description => 'Mark a workflow as successfully completed';

  @override
  String get usage =>
      'shepaw workflow complete --workflow_id <id> --summary "All tasks done"';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final workflowId = flags['workflow_id'];
    final summary = flags['summary'];

    if (workflowId == null || workflowId.isEmpty) {
      return {'error': 'Missing required flag: --workflow_id'};
    }

    final workflowService = WorkflowService(db: LocalDatabaseService());
    final workflow =
        await workflowService.getWorkflowExecutionWithSteps(workflowId);

    if (workflow == null) {
      return {'error': 'Workflow not found: $workflowId'};
    }

    await workflowService.completeWorkflow(workflowId, summary: summary);

    return {
      'workflow_id': workflowId,
      'status': 'completed',
      'title': workflow.title,
      'total_steps': workflow.totalSteps,
      'completed_steps': workflow.completedSteps,
      'duration': workflow.durationLabel,
      'message': '工作流 "${workflow.title}" 已标记为完成。',
    };
  }
}

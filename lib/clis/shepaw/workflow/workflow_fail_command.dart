import '../../cli_base.dart';
import '../../../services/workflow/workflow_service.dart';
import '../../../services/local_database_service.dart';

/// 标记工作流执行失败。
///
/// 用法：
///   shepaw workflow fail --workflow_id <id> [--reason "失败原因"]
class WorkflowFailCommand extends CliCommand {
  @override
  String get name => 'fail';

  @override
  String get description => 'Mark a workflow as failed';

  @override
  String get usage =>
      'shepaw workflow fail --workflow_id <id> --reason "Step 2 agent timeout"';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final workflowId = flags['workflow_id'];
    final reason = flags['reason'] ?? 'Workflow marked as failed by Admin';

    if (workflowId == null || workflowId.isEmpty) {
      return {'error': 'Missing required flag: --workflow_id'};
    }

    final workflowService = WorkflowService(db: LocalDatabaseService());
    final workflow =
        await workflowService.getWorkflowExecutionWithSteps(workflowId);

    if (workflow == null) {
      return {'error': 'Workflow not found: $workflowId'};
    }

    await workflowService.failWorkflow(workflowId, reason);

    return {
      'workflow_id': workflowId,
      'status': 'failed',
      'reason': reason,
      'message': '工作流 "${workflow.title}" 已标记为失败。',
    };
  }
}

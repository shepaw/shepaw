import '../../cli_base.dart';
import '../../../models/workflow_models.dart';
import '../../../services/workflow/workflow_service.dart';

/// 取消工作流。
///
/// 用法：
///   shepaw workflow cancel --workflow_id <id> [--reason "取消原因"]
class WorkflowCancelCommand extends CliCommand {
  @override
  String get name => 'cancel';

  @override
  String get description => 'Cancel a workflow';

  @override
  String get usage =>
      'shepaw workflow cancel --workflow_id <id> --reason "User requested cancellation"';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final workflowId = flags['workflow_id'];
    final reason = flags['reason'];

    if (workflowId == null || workflowId.isEmpty) {
      return {'error': 'Missing required flag: --workflow_id'};
    }

    final workflowService = WorkflowService.instance;
    final workflow =
        await workflowService.getWorkflowExecutionWithSteps(workflowId);

    if (workflow == null) {
      return {'error': 'Workflow not found: $workflowId'};
    }

    // H2: Status guard — only allow cancelling pending or running workflows
    if (workflow.status != WorkflowStatus.pendingApproval &&
        workflow.status != WorkflowStatus.running) {
      return {
        'error': 'Cannot cancel workflow in "${workflow.status.label}" state. Only pending or running workflows can be cancelled.',
      };
    }

    await workflowService.cancelWorkflow(workflowId);

    return {
      'workflow_id': workflowId,
      'status': 'cancelled',
      if (reason != null) 'reason': reason,
      'message': '工作流 "${workflow.title}" 已取消。',
    };
  }
}

import 'dart:convert';
import '../../cli_base.dart';
import '../../../models/planning_models.dart';
import '../../../services/workflow/workflow_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/task/plan_approval_service.dart';
import 'workflow_namespace.dart';

/// 创建工作流并提交用户审批。
///
/// 用法：
///   shepaw workflow create --title "标题" --summary "摘要" --stages '[...]'
///
/// stages JSON 格式：
/// ```json
/// [
///   {
///     "label": "阶段名",
///     "steps": [
///       {"agent": "AgentName", "instruction": "指令内容"}
///     ]
///   }
/// ]
/// ```
///
/// 命令会阻塞等待用户审批结果后返回。
class WorkflowCreateCommand extends CliCommand {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a workflow plan and submit for user approval';

  @override
  String get usage =>
      'shepaw workflow create --title "Refactor auth" --summary "..." --stages \'[{"label":"Phase 1","steps":[{"agent":"CodeBot","instruction":"Analyze code"}]}]\'';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final title = flags['title'];
    final summary = flags['summary'] ?? '';
    final stagesJson = flags['stages'];
    final channelId = WorkflowNamespace.instance.channelId;

    if (title == null || title.isEmpty) {
      return {'error': 'Missing required flag: --title'};
    }
    if (stagesJson == null || stagesJson.isEmpty) {
      return {'error': 'Missing required flag: --stages (JSON array)'};
    }
    if (channelId == null || channelId.isEmpty) {
      return {'error': 'No active channel context. This command must be used in a group chat.'};
    }

    // Parse stages JSON
    List<dynamic> stagesList;
    try {
      stagesList = jsonDecode(stagesJson) as List<dynamic>;
    } catch (e) {
      return {'error': 'Invalid --stages JSON: $e'};
    }

    if (stagesList.isEmpty) {
      return {'error': '--stages must contain at least one stage'};
    }

    // Build FlowPlan from stages
    final stages = <FlowStage>[];
    for (int si = 0; si < stagesList.length; si++) {
      final stageData = stagesList[si] as Map<String, dynamic>;
      final label = stageData['label'] as String? ?? '阶段 ${si + 1}';
      final stepsData = stageData['steps'] as List<dynamic>? ?? [];

      final steps = <FlowStep>[];
      for (int sti = 0; sti < stepsData.length; sti++) {
        final stepData = stepsData[sti] as Map<String, dynamic>;
        steps.add(FlowStep(
          stepId: 's${si}_t$sti',
          taskId: 'task_${si}_$sti',
          agent: stepData['agent'] as String? ?? '',
          instruction: stepData['instruction'] as String? ?? '',
          dependsOn: (stepData['depends_on'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [],
          estimatedComplexity:
              stepData['estimated_complexity'] as String? ?? 'medium',
        ));
      }

      stages.add(FlowStage(
        stageId: 's$si',
        label: label,
        steps: steps,
      ));
    }

    final flowPlan = FlowPlan(
      title: title,
      summary: summary,
      stages: stages,
    );

    // Create workflow execution record
    final workflowService = WorkflowService(db: LocalDatabaseService());
    final execution = await workflowService.createWorkflowExecution(
      channelId: channelId,
      title: title,
      flowPlan: flowPlan,
      triggerMessage: flags['trigger_message'],
    );

    // Wait for user approval via PlanApprovalService
    final approvalService = PlanApprovalService();
    final planData = {
      ...flowPlan.toExecutionPlan().toJson(),
      '_workflowId': execution.id,
    };

    final approvalResult = await approvalService.awaitPlanApproval(
      channelId: channelId,
      agentId: WorkflowNamespace.instance.agentId ?? '',
      agentName: '',
      planData: planData,
      messageId: '',
    );

    if (approvalResult == null || approvalResult['approved'] != true) {
      await workflowService.cancelWorkflow(execution.id);
      final feedback = approvalResult?['feedback'] as String?;
      return {
        'workflow_id': execution.id,
        'status': 'rejected',
        if (feedback != null) 'feedback': feedback,
        'message': '用户拒绝了工作流计划${feedback != null ? "，反馈：$feedback" : ""}',
      };
    }

    // Apply skipped steps
    final skippedIds = ((approvalResult['skipped_task_ids'] as List?)
            ?.map((e) => e.toString())
            .toSet()) ??
        <String>{};
    if (skippedIds.isNotEmpty) {
      final exec =
          await workflowService.getWorkflowExecutionWithSteps(execution.id);
      if (exec != null) {
        for (final step in exec.steps) {
          final stepKey = 's${step.stageIndex}_t${step.stepIndex}';
          if (skippedIds.contains(stepKey)) {
            await workflowService.skipStep(step.id);
          }
        }
      }
    }

    // Mark as running
    await workflowService.startWorkflow(execution.id);

    return {
      'workflow_id': execution.id,
      'status': 'approved',
      'title': title,
      'total_stages': stages.length,
      'total_steps': stages.fold<int>(0, (sum, s) => sum + s.steps.length),
      'message': '工作流已获批准，可以开始执行。请逐阶段调用 workflow dispatch。',
    };
  }
}

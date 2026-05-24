import 'dart:convert';
import '../../cli_base.dart';
import '../../../models/planning_models.dart';
import '../../../services/workflow/workflow_service.dart';

/// 创建工作流计划。
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
/// 创建后系统会向用户展示审批卡片。
/// 命令立即返回 workflow_id 和 pending_approval 状态。
/// Admin 应等待用户审批后再调用 `workflow dispatch`。
class WorkflowCreateCommand extends CliCommand {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a workflow plan (pending user approval)';

  @override
  String get usage =>
      'shepaw workflow create --title "Refactor auth" --summary "..." --stages \'[{"label":"Phase 1","steps":[{"agent":"CodeBot","instruction":"Analyze code"}]}]\'';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final title = flags['title'];
    final summary = flags['summary'] ?? '';
    final stagesJson = flags['stages'];
    final channelId = flags['channel_id'];

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
    final workflowService = WorkflowService.instance;
    final execution = await workflowService.createWorkflowExecution(
      channelId: channelId,
      title: title,
      flowPlan: flowPlan,
      triggerMessage: flags['trigger_message'],
    );

    // Return immediately with pending_approval status.
    // The GroupAgentExecutor will handle showing the approval UI
    // and the user approval flow externally.
    return {
      'workflow_id': execution.id,
      'status': 'pending_approval',
      'title': title,
      'total_stages': stages.length,
      'total_steps': stages.fold<int>(0, (sum, s) => sum + s.steps.length),
      'message': '工作流已创建，等待用户审批。审批通过后请调用 workflow dispatch 开始执行。',
      '_plan_data': flowPlan.toExecutionPlan().toJson(),
    };
  }
}

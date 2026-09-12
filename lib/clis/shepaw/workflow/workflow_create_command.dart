import 'dart:convert';
import '../../cli_base.dart';
import '../../../models/planning_models.dart';
import '../../../services/workflow/workflow_service.dart';
import '../models/models_cli_helpers.dart';

/// 创建工作流计划。
///
/// 用法：
///   shepaw workflow create --title "标题" --summary "摘要" --stages '[...]'
///       [--require-approval true|false]
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
/// 默认请求用户审批（`pending_approval`）。管理员可传
/// `--require-approval false` 跳过审批并立即执行。
/// 群聊 Flow Mode 与 She 的 1:1 私聊一致：进入 running 后由系统自动执行
/// 全部阶段（ChatService.executeWorkflowSteps），无需再调 dispatch；
/// `workflow dispatch` 仅用于手动重试某一阶段。
class WorkflowCreateCommand extends CliCommand {
  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a workflow plan (optional user approval)';

  @override
  String get usage =>
      'shepaw workflow create --title "Refactor auth" --summary "..." --stages \'[{"label":"Phase 1","steps":[{"agent":"CodeBot","instruction":"Analyze code"}]}]\' [--require-approval true|false]';

  /// Default `true` when the flag is omitted or present with an empty value.
  static ({bool? value, String? error}) parseRequireApprovalFlag(
    Map<String, String> flags,
  ) {
    final raw = flags['require-approval'] ?? flags['require_approval'];
    if (raw == null || raw.trim().isEmpty) {
      return (value: true, error: null);
    }
    return parseBoolFlag(raw, '--require-approval');
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final title = flags['title'];
    final summary = flags['summary'] ?? '';
    final stagesJson = flags['stages'];
    final channelId = flags['channel_id'];
    final approval = parseRequireApprovalFlag(flags);
    if (approval.error != null) {
      return {'error': approval.error};
    }
    final requireApproval = approval.value ?? true;

    if (title == null || title.isEmpty) {
      return {'error': 'Missing required flag: --title'};
    }
    if (stagesJson == null || stagesJson.isEmpty) {
      return {'error': 'Missing required flag: --stages (JSON array)'};
    }
    if (channelId == null || channelId.isEmpty) {
      return {'error': 'No active channel context.'};
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

    final workflowService = WorkflowService.instance;
    final execution = await workflowService.createWorkflowExecution(
      channelId: channelId,
      title: title,
      flowPlan: flowPlan,
      triggerMessage: flags['trigger_message'],
      requireApproval: requireApproval,
    );

    if (requireApproval) {
      return {
        'workflow_id': execution.id,
        'status': 'pending_approval',
        'require_approval': true,
        'title': title,
        'total_stages': stages.length,
        'total_steps': stages.fold<int>(0, (sum, s) => sum + s.steps.length),
        'message': '工作流已创建，等待用户审批。审批通过后系统会自动开始执行。',
        '_plan_data': flowPlan.toExecutionPlan().toJson(),
      };
    }

    return {
      'workflow_id': execution.id,
      'status': 'running',
      'require_approval': false,
      'title': title,
      'total_stages': stages.length,
      'total_steps': stages.fold<int>(0, (sum, s) => sum + s.steps.length),
      'message': '工作流已创建并立即开始执行（未请求用户审批）。',
      '_plan_data': flowPlan.toExecutionPlan().toJson(),
      '_auto_start': true,
    };
  }
}

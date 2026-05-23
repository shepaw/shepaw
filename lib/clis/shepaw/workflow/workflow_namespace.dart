import '../../cli_base.dart';
import 'workflow_create_command.dart';
import 'workflow_dispatch_command.dart';
import 'workflow_status_command.dart';
import 'workflow_complete_command.dart';
import 'workflow_fail_command.dart';
import 'workflow_cancel_command.dart';

/// [TOOLING 层] workflow 命名空间 — 群工作流规划和执行管理
///
/// 仅供群内 Admin Agent 调用，用于创建、分发、管理工作流。
///
/// Subcommands:
/// - `create`    创建工作流（阶段化计划），提交用户审批
/// - `dispatch`  将指定阶段的步骤委派给成员 Agent 执行
/// - `status`    查看当前工作流执行状态
/// - `complete`  标记工作流成功完成
/// - `fail`      标记工作流失败
/// - `cancel`    取消工作流
class WorkflowNamespace extends CliNamespace {
  static final instance = WorkflowNamespace._();
  WorkflowNamespace._();

  /// 当前执行的 channelId（由外部在调用前注入）
  String? channelId;

  /// 当前执行的 agentId（由外部在调用前注入）
  String? agentId;

  @override
  String get namespace => 'workflow';

  @override
  String get description => 'Group workflow planning and execution (Admin only)';

  @override
  Map<String, CliCommand> get commands => {
        'create': WorkflowCreateCommand(),
        'dispatch': WorkflowDispatchCommand(),
        'status': WorkflowStatusCommand(),
        'complete': WorkflowCompleteCommand(),
        'fail': WorkflowFailCommand(),
        'cancel': WorkflowCancelCommand(),
      };
}

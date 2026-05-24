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

  /// Per-channel context for concurrent safety (C1 fix).
  /// Keyed by channelId so multiple groups can run workflows simultaneously.
  final Map<String, _WorkflowContext> _contexts = {};

  /// Set context for a specific channel before CLI execution.
  void setContext(String channelId, String agentId) {
    _contexts[channelId] = _WorkflowContext(channelId: channelId, agentId: agentId);
  }

  /// Clear context for a specific channel after CLI execution.
  void clearContext(String channelId) {
    _contexts.remove(channelId);
  }

  /// Get the channelId for a given context (looked up by channel_id flag in CLI args).
  String? getChannelId(String? fromFlags) => fromFlags ?? _contexts.values.firstOrNull?.channelId;

  /// Get the agentId for a given channel context.
  String? getAgentId(String? channelId) => channelId != null ? _contexts[channelId]?.agentId : null;

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

class _WorkflowContext {
  final String channelId;
  final String agentId;
  _WorkflowContext({required this.channelId, required this.agentId});
}

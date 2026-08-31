import '../../cli_base.dart';
import '../../../models/instruction_set.dart';
import '../../../services/she_service.dart';
import '../../../services/local_user_identity.dart';
import '../chat/chat_agent_scope.dart';
import 'save_command.dart';
import 'list_command.dart';
import 'get_command.dart';
import 'update_command.dart';
import 'delete_command.dart';
import 'run_command.dart';

/// [TOOLING 层] instructions 命名空间 - 可复用的任务指令集
///
/// 指令集是把「对话中执行过的某项任务」沉淀成一条可复用的指令：
/// - `save`    保存指令，记录当前执行 agent 为所属 agent（所有 agent 可用）
/// - `list`    列出指令（可按 `--owner` 过滤）
/// - `get`     读取单条指令完整内容
/// - `update` / `delete` 修改/删除——仅用户、She 或所属 agent 可操作
/// - `run`     执行指令，自动路由给所属 agent
///
/// 用户在对话中说「帮我生成/保存一个指令」时，agent 应调用 `save`。
class InstructionsNamespace extends CliNamespace {
  static final instance = InstructionsNamespace._();
  InstructionsNamespace._();

  @override
  String get namespace => 'instructions';

  @override
  String get description =>
      'Reusable task instructions: save/list/get/update/delete/run '
      '(run auto-routes to the owning agent)';

  @override
  String get icon => '📌';

  @override
  Map<String, CliCommand> get commands => {
        'save': SaveInstructionCommand(),
        'list': ListInstructionsCommand(),
        'get': GetInstructionCommand(),
        'update': UpdateInstructionCommand(),
        'delete': DeleteInstructionCommand(),
        'run': RunInstructionCommand(),
      };
}

/// 修改/删除指令的权限校验：仅用户、She 或指令所属 agent 可操作。
///
/// 返回 null 表示允许；返回 String 为拒绝原因。
Future<String?> instructionManageError(InstructionSet instruction) async {
  final actor = ChatAgentScope.agentId.trim();
  if (actor == SheService.sheId || actor == LocalUserIdentity.id) return null;
  if (instruction.ownerAgentId == actor) return null;
  final ownerLabel = instruction.ownerAgentName.isNotEmpty
      ? instruction.ownerAgentName
      : instruction.ownerAgentId;
  return 'Permission denied: only the user, She, or the owning agent '
      '($ownerLabel) can modify or delete this instruction.';
}

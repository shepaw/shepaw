import '../../cli_base.dart';
import '../../../services/instruction_set_service.dart';
import '../chat/chat_agent_scope.dart';
import 'instructions_namespace.dart';

/// `shepaw instructions save --name <name> --content <text> [--desc <text>]`
///
/// 保存一条可复用的任务指令，并把当前执行 agent 记录为所属 agent
/// （下次 `instructions run` 会自动路由给它执行）。所有 agent 可用。
///
/// 若同名指令已存在则转为更新（受权限约束：仅用户 / She / 所属 agent）。
class SaveInstructionCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'save';

  @override
  String get description =>
      'Save a reusable task instruction. Records the current agent as its '
      'owner; run later auto-routes execution to that agent. '
      'Call this when the user asks you to save/summarize a task as an '
      'instruction.';

  @override
  String get usage =>
      'shepaw instructions save --name "quarterly report" '
      '--content "Summarize Q2 sales, top 3 wins and risks" [--desc "..."]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name']?.trim() ?? '';
    final content = flags['content']?.trim() ?? '';
    if (name.isEmpty) {
      return {'error': 'Missing --name. Usage: $usage'};
    }
    if (content.isEmpty) {
      return {'error': 'Missing --content. Usage: $usage'};
    }

    final existing = await _service.getByName(name);
    if (existing != null) {
      final denied = await instructionManageError(existing);
      if (denied != null) return {'error': denied};
      final updated = await _service.update(
        id: existing.id,
        description: flags['desc'],
        content: content,
      );
      return {
        'success': true,
        'action': 'updated',
        'id': updated.id,
        'name': updated.name,
        'owner_agent_id': updated.ownerAgentId,
        'owner_agent_name': updated.ownerAgentName,
        'note': 'Instruction updated. To execute later: '
            'shepaw instructions run --name "${updated.name}"',
      };
    }

    final created = await _service.create(
      name: name,
      description: flags['desc'],
      content: content,
      ownerAgentId: ChatAgentScope.agentId,
    );
    return {
      'success': true,
      'action': 'created',
      'id': created.id,
      'name': created.name,
      'owner_agent_id': created.ownerAgentId,
      'note': 'Instruction saved. Next time it runs, it will be routed to you '
          '(the owning agent): shepaw instructions run --name "${created.name}"',
    };
  }
}

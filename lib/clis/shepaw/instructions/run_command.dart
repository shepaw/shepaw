import '../../cli_base.dart';
import '../../../services/agent_resolver.dart';
import '../../../services/dispatch/dispatch_service.dart';
import '../../../services/instruction_set_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';
import '../chat/chat_agent_scope.dart';

/// `shepaw instructions run --name <name> [--channel <channel_id>]`
///
/// 执行一条已保存的指令，自动路由给所属 agent：
/// - 所属 agent 是当前执行者或 She → 直接返回指令内容，要求当前 agent 执行；
/// - 所属 agent 是其他可派发 agent → 通过 dispatch 派发给它执行，结果回传当前频道。
class RunInstructionCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'run';

  @override
  String get description =>
      'Execute a saved instruction — auto-routes to the agent that owns it '
      '(dispatch to the owning agent, or run directly if owned by you / She)';

  @override
  String get usage =>
      'shepaw instructions run --name <name> [--channel <channel_id>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name']?.trim() ?? '';
    if (name.isEmpty) {
      return {'error': 'Missing --name. Usage: $usage'};
    }
    final item = await _service.getByName(name);
    if (item == null) {
      return {'error': 'Instruction not found: $name'};
    }

    final currentAgent = ChatAgentScope.agentId.trim();
    final ownerId = item.ownerAgentId.trim();
    final ownerLabel = item.ownerAgentName.isNotEmpty
        ? item.ownerAgentName
        : ownerId;

    // 所属 agent 是当前执行者或 She → 就地执行。
    if (ownerId == currentAgent || ownerId == SheService.sheId) {
      return {
        'success': true,
        'instruction': item.name,
        'description': item.description ?? '',
        'content': item.content,
        'owner_agent_id': ownerId,
        'owner_agent_name': item.ownerAgentName,
        'note': ownerId == SheService.sheId && ownerId != currentAgent
            ? 'This instruction is owned by She. Perform the task described '
                'below yourself on behalf of your master.'
            : 'Execute this instruction content now as your current task. '
                'Actually perform the task — do not just acknowledge it.',
      };
    }

    // 所属 agent 是其他 agent → 派发给它执行。
    final sourceChannelId = flags['channel_id']?.trim() ?? ChatAgentScope.channelId;
    if (sourceChannelId.isEmpty) {
      return {
        'success': true,
        'instruction': item.name,
        'content': item.content,
        'owner_agent_id': ownerId,
        'owner_agent_name': item.ownerAgentName,
        'note': 'This instruction belongs to $ownerLabel. There is no active '
            'channel to report back to, so perform the task described below '
            'yourself, or ask your master to run it with the owning agent.',
      };
    }

    final targetAgent =
        await AgentResolver.byIdOrName(LocalDatabaseService(), ownerId);
    if (targetAgent == null) {
      return {
        'error': 'Owner agent not found: $ownerId. Cannot auto-route execution.',
        'instruction': item.name,
        'content': item.content,
        'note': 'Perform the task described above yourself, or create the '
            'agent again and re-run.',
      };
    }

    final result = await DispatchService.instance.dispatch(
      sourceChannelId: sourceChannelId,
      targetAgent: targetAgent,
      prompt: '执行指令「${item.name}」：\n${item.content}',
    );
    return {
      'success': true,
      'dispatched_to': targetAgent.name,
      'instruction': item.name,
      'result': result,
      'note': 'The instruction has been dispatched to its owning agent '
          '$ownerLabel to execute.',
    };
  }
}

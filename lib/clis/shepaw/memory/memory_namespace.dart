import '../../cli_base.dart';
import '../../../services/she_service.dart';
import 'query_command.dart';
import 'write_command.dart';
import 'append_command.dart';

/// memory namespace - Agent memory management
///
/// 支持所有 Agent 访问各自的记忆数据。
/// agentId 由 ContextNamespace 在每次调用前注入。
class MemoryNamespace extends CliNamespace {
  static final instance = MemoryNamespace._();
  MemoryNamespace._();

  /// 当前执行命令的 Agent ID
  String agentId = SheService.sheId;

  @override
  String get namespace => 'memory';

  @override
  String get description => "Agent's memories (soul / long_term_memory / heartbeat / ...)";

  @override
  Map<String, CliCommand> get commands => {
    'query': QueryCommand(agentId: agentId),
    'write': WriteCommand(agentId: agentId),
    'append': AppendCommand(agentId: agentId),
  };

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['keys'] = [
      'soul (self-awareness, replace entire entry)',
      'self_notes (personal notes, append using append command)',
      'long_term_memory (long-term memory, append using append command)',
      'heartbeat (last conversation summary)',
      'user_info (overall impression of the user)',
      'capabilities (capability index)',
    ];
    return base;
  }
}

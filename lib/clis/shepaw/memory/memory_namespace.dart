import '../../cli_base.dart';
import 'query_command.dart';
import 'write_command.dart';
import 'append_command.dart';

/// memory namespace - She's memory management
class MemoryNamespace extends CliNamespace {
  static final instance = MemoryNamespace._();
  MemoryNamespace._();

  @override
  String get namespace => 'memory';

  @override
  String get description => "She's memories (she_memory table)";

  @override
  Map<String, CliCommand> get commands => {
    'query': QueryCommand(),
    'write': WriteCommand(),
    'append': AppendCommand(),
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

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
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {
      'query': 'Query memory, optional --keys soul,heartbeat,...',
      'write': 'Write memory, --key <key> --value <val>',
      'append': 'Append content, --key long_term_memory|self_notes --value <val>',
    },
    'keys': [
      'soul (self-awareness, replace entire entry)',
      'self_notes (personal notes, append using append command)',
      'long_term_memory (long-term memory, append using append command)',
      'heartbeat (last conversation summary)',
      'user_info (overall impression of the user)',
      'capabilities (capability index)',
    ],
    'examples': [
      'shepaw memory query',
      'shepaw memory query --keys soul,user_info',
      'shepaw memory write --key soul --value "I am..."',
      'shepaw memory append --key long_term_memory --value "User mentioned..."',
    ],
  };
}

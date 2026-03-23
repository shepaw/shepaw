import '../../cli_base.dart';
import 'query_command.dart';

/// messages 命名空间 - 频道消息查询
class MessagesNamespace extends CliNamespace {
  static final instance = MessagesNamespace._();
  MessagesNamespace._();

  @override
  String get namespace => 'messages';

  @override
  String get description => 'Channel messages';

  @override
  Map<String, CliCommand> get commands => {
    'query': QueryCommand(),
  };

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {
      'query': 'Query messages, --channel <id> or --agent <agent_id>, optional --limit N (default 20) --offset N (default 0)',
    },
    'examples': [
      'shepaw messages query --channel abc123 --limit 10',
      'shepaw messages query --agent <agent_id> --limit 20 --offset 0',
    ],
  };
}

import '../../cli_base.dart';
import 'list_command.dart';
import 'get_command.dart';
import 'channels_command.dart';
import 'messages_command.dart';
import 'chat_command.dart';
import 'memory_query_command.dart';
import 'memory_write_command.dart';
import 'cognition_query_command.dart';
import 'cognition_write_command.dart';

/// agents 命名空间 - 已添加的 AI 助手管理
class AgentsNamespace extends CliNamespace {
  static final instance = AgentsNamespace._();
  AgentsNamespace._();

  final _chatCommand = ChatCommand();

  /// Injected via ShepawCLI — forwarded to ChatCommand
  set chatSender(IPawChatSender? sender) => _chatCommand.chatSender = sender;

  @override
  String get namespace => 'agents';

  @override
  String get description => 'Added AI assistants';

  @override
  Map<String, CliCommand> get commands => {
        'list': ListCommand(),
        'get': GetCommand(),
        'channels': ChannelsCommand(),
        'messages': MessagesCommand(),
        'chat': _chatCommand,
        'memory-query': MemoryQueryCommand(),
        'memory-write': MemoryWriteCommand(),
        'cognition-query': CognitionQueryCommand(),
        'cognition-write': CognitionWriteCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List agents, optional --status <online|offline|all>',
          'get': 'Get agent details, --id <agent_id>',
          'channels': 'List agent conversation channels, --id <agent_id>',
          'messages':
              'Query agent channel messages, --id <agent_id> [--channel <channel_id>] [--limit 20] [--offset 0]',
          'chat':
              'Send message to agent as She, --id <agent_id> --message <text> [--channel <channel_id>]',
        'memory-query':
            'Query agent memories, --id <agent_id> [--keywords k1,k2] [--type conversation] [--limit 20]',
        'memory-write':
            'Write agent memory, --id <agent_id> --content "..." [--type conversation|knowledge|behavior|event|emotion] [--keywords k1,k2]',
        'cognition-query':
            'Query agent cognition, --id <agent_id> [--type self|user]',
        'cognition-write':
            'Write agent cognition, --id <agent_id> --type self --soul "..." OR --type user --field impression|notes --value "..."',
        },
        'examples': [
          'shepaw agents list',
          'shepaw agents list --status online',
          'shepaw agents get --id <agent_id>',
          'shepaw agents channels --id <agent_id>',
          'shepaw agents messages --id <agent_id>',
          'shepaw agents messages --id <agent_id> --channel <channel_id> --limit 20 --offset 0',
          'shepaw agents chat --id <agent_id> --message "Hello" [--channel <channel_id>]',
          'shepaw agents memory-query --id <agent_id> --limit 10',
          'shepaw agents memory-query --id <agent_id> --keywords user,preference --limit 20',
          'shepaw agents memory-write --id <agent_id> --content "User prefers concise replies" --type preference --keywords preference',
          'shepaw agents cognition-query --id <agent_id>',
          'shepaw agents cognition-query --id <agent_id> --type self',
          'shepaw agents cognition-write --id <agent_id> --type self --soul "I am a helpful assistant..."',
          'shepaw agents cognition-write --id <agent_id> --type user --field impression --value "User prefers concise replies"',
        ],
      };
}

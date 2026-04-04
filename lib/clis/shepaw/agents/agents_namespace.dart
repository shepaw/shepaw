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
}

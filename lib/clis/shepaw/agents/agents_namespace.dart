import '../../cli_base.dart';
import 'list_command.dart';
import 'get_command.dart';
import 'channels_command.dart';
import 'messages_command.dart';
import 'chat_command.dart';
import 'dispatch_command.dart';
import 'memory_query_command.dart';
import 'memory_write_command.dart';
import 'cognition_query_command.dart';
import 'cognition_write_command.dart';

/// agents 命名空间 - 已添加的 AI 助手管理
class AgentsNamespace extends CliNamespace {
  static final instance = AgentsNamespace._();
  AgentsNamespace._();

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
        'chat': ChatCommand(),
        'dispatch': DispatchCommand(),
        'memory-query': MemoryQueryCommand(),
        'memory-write': MemoryWriteCommand(),
        'cognition-query': CognitionQueryCommand(),
        'cognition-write': CognitionWriteCommand(),
      };
}

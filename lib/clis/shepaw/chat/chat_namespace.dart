import '../../cli_base.dart';
import 'channels_command.dart';
import 'messages_command.dart';

/// [COMMUNICATION 层] chat 命名空间 - 对话频道和消息管理
///
/// 统一管理对话频道的浏览和消息的查询。
///
/// Subcommands:
/// - `channels`  列出所有对话频道
/// - `messages`  查询频道消息（--channel <id> 或 --agent <agent_id>）
class ChatNamespace extends CliNamespace {
  static final instance = ChatNamespace._();
  ChatNamespace._();

  @override
  String get namespace => 'chat';

  @override
  String get description => 'Conversation channels and messages';

  @override
  Map<String, CliCommand> get commands => {
        'channels': ChatChannelsCommand(),
        'messages': ChatMessagesCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'channels': 'List all conversation channels',
          'messages':
              'Query messages — --channel <id> or --agent <agent_id>, optional --limit N (default 20) --offset N (default 0)',
        },
        'examples': [
          'shepaw chat channels',
          'shepaw chat messages --channel abc123 --limit 10',
          'shepaw chat messages --agent <agent_id> --limit 20 --offset 0',
        ],
      };
}

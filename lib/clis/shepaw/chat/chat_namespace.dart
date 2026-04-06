import '../../cli_base.dart';
import '../../../services/she_service.dart';
import 'channels_command.dart';
import 'messages_command.dart';

/// [COMMUNICATION 层] chat 命名空间 - 对话频道和消息管理
///
/// 统一管理对话频道的浏览和消息的查询。
/// 通过 agentId 属性支持所有 Agent 访问各自的对话数据。
///
/// Subcommands:
/// - `channels`  列出所有对话频道
/// - `messages`  查询频道消息（--channel <id> 或 --agent <agent_id>）
class ChatNamespace extends CliNamespace {
  static final instance = ChatNamespace._();
  ChatNamespace._();

  /// 当前执行命令的 Agent ID
  /// 由 ShepawCLI.execute() 在每次调用前注入
  String agentId = SheService.sheId;

  @override
  String get namespace => 'chat';

  @override
  String get description => 'Conversation channels and messages';

  @override
  Map<String, CliCommand> get commands => {
        'channels': ChatChannelsCommand(),
        'messages': ChatMessagesCommand(agentId: agentId),
      };
}

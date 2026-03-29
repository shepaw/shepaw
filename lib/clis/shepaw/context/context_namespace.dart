import '../../cli_base.dart';
import '../profile/profile_namespace.dart';
import '../memory/memory_namespace.dart';
import '../agents/agents_namespace.dart';

/// [CONTEXT 层] context 命名空间 - She 的内部状态管理
///
/// 统一管理 She 的档案、记忆、以及已添加的 AI 助手。
///
/// 使用分层路由，subcommand 格式为 `<sub-namespace>.<action>`：
///
/// Sub-namespaces:
/// - `profile`  用户档案（fields / query / write / delete）
/// - `memory`   She 的记忆（query / write / append）
/// - `agents`   AI 助手管理（list / get / channels / messages / chat /
///              memory-query / memory-write / cognition-query / cognition-write）
///
/// 示例：
/// ```
/// shepaw context profile.query
/// shepaw context profile.write --field name --value John
/// shepaw context memory.query --keys soul,user_info
/// shepaw context memory.write --key soul --value "I am..."
/// shepaw context agents.list --status online
/// shepaw context agents.chat --id <agent_id> --message "Hello"
/// ```
class ContextNamespace extends CliNamespace {
  static final instance = ContextNamespace._();
  ContextNamespace._();

  /// chatSender 透传给 AgentsNamespace
  set chatSender(IPawChatSender? sender) =>
      AgentsNamespace.instance.chatSender = sender;

  @override
  String get namespace => 'context';

  @override
  String get description => "She's internal state — profile, memory, agents";

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'profile': ProfileNamespace.instance,
        'memory': MemoryNamespace.instance,
        'agents': AgentsNamespace.instance,
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'usage': 'shepaw context <sub-namespace>.<action> [flags]',
        'sub_namespaces': {
          'profile': {
            'desc': ProfileNamespace.instance.description,
            'actions': ProfileNamespace.instance.commands.keys.toList(),
          },
          'memory': {
            'desc': MemoryNamespace.instance.description,
            'actions': MemoryNamespace.instance.commands.keys.toList(),
          },
          'agents': {
            'desc': AgentsNamespace.instance.description,
            'actions': AgentsNamespace.instance.commands.keys.toList(),
          },
        },
        'examples': [
          'shepaw context profile.fields',
          'shepaw context profile.query',
          'shepaw context profile.write --field name --value John',
          'shepaw context profile.delete --field notes',
          'shepaw context memory.query --keys soul,user_info',
          'shepaw context memory.write --key soul --value "I am..."',
          'shepaw context memory.append --key long_term_memory --value "User mentioned..."',
          'shepaw context agents.list --status online',
          'shepaw context agents.get --id <agent_id>',
          'shepaw context agents.chat --id <agent_id> --message "Hello"',
          'shepaw context agents.memory-query --id <agent_id> --limit 10',
          'shepaw context agents.cognition-query --id <agent_id>',
        ],
      };
}

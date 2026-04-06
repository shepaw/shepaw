import '../../cli_base.dart';
import '../../../services/she_service.dart';
import '../profile/profile_namespace.dart';
import '../memory/memory_namespace.dart';
import '../agents/agents_namespace.dart';

/// [CONTEXT 层] context 命名空间 - Agent 的内部状态管理
///
/// 统一管理 Agent 的档案、记忆、以及已添加的 AI 助手。
/// 通过 agentId 属性支持所有 Agent 访问各自的数据。
///
/// 使用分层路由，subcommand 格式为 `<sub-namespace>.<action>`：
///
/// Sub-namespaces:
/// - `profile`  用户档案（fields / query / write / delete）
/// - `memory`   Agent 的记忆（query / write / append）
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

  /// 当前执行命令的 Agent ID
  /// 由 ShepawCLI.execute() 在每次调用前注入
  String get agentId => _agentId;
  String _agentId = SheService.sheId;
  set agentId(String id) {
    _agentId = id;
    MemoryNamespace.instance.agentId = id;
  }

  /// chatSender 透传给 AgentsNamespace
  set chatSender(IPawChatSender? sender) =>
      AgentsNamespace.instance.chatSender = sender;

  @override
  String get namespace => 'context';

  @override
  String get description => "Agent's internal state — profile, memory, agents";

  @override
  String get usage => 'shepaw context <sub-namespace>.<action> [flags]';

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'profile': ProfileNamespace.instance,
        'memory': MemoryNamespace.instance,
        'agents': AgentsNamespace.instance,
      };
}

import 'dart:convert';
import '../cli_base.dart';
import 'context/context_namespace.dart';
import 'chat/chat_namespace.dart';
import 'skills_namespace.dart';
import 'tools_namespace.dart';
import 'meta/meta_namespace.dart';
import 'help_namespace.dart';
import '../../services/logger_service.dart';
import '../../services/cli_command_config_service.dart';

/// ShepawCLI — She 专属的内嵌 CLI，替代 PawToolRegistry。
///
/// CLI 风格：
///   shepaw <namespace> [subcommand] [--flag value ...]
///
/// 命名空间按功能职责分为 4 个层级：
///
/// ─── 🧠 CONTEXT 层（She 的内部状态）─────────────────────────
///   context   档案 / 记忆 / AI 助手（profile.* / memory.* / agents.*）
///
/// ─── 💬 COMMUNICATION 层（实时对话和通信）───────────────────
///   chat      对话频道与消息（channels / messages）
///
/// ─── 🔧 TOOLING 层（系统工具和功能能力）────────────────────
///   tools     本地系统工具（OS tools、文件操作等）
///   skills    已加载的 LLM 技能库（user-imported skills）
///
/// ─── ℹ️ META 层（系统元信息和诊断）─────────────────────────
///   meta      系统信息、时间（system.* / datetime）
///   help      顶层帮助（顶级命令，动态聚合所有命名空间）
///
/// 详细架构文档见 NAMESPACE_ARCHITECTURE.md
class ShepawCLI {
  static final ShepawCLI instance = ShepawCLI._();
  ShepawCLI._();

  static const String toolName = 'shepaw';

  /// chatSender 注入点，由 ChatService 在启动时设置
  set chatSender(IPawChatSender? sender) {
    ContextNamespace.instance.chatSender = sender;
  }

  // ── 命名空间注册表 ───────────────────────────────────────────────────────────

  late final Map<String, CliNamespace> _namespaces = {
    // ── 🧠 CONTEXT 层 - She 的内部状态 ──────────────────────────────────────────
    'context': ContextNamespace.instance,

    // ── 💬 COMMUNICATION 层 - 实时对话和通信 ────────────────────────────────────
    'chat': ChatNamespace.instance,

    // ── 🔧 TOOLING 层 - 系统工具和功能能力 ──────────────────────────────────────
    'tools': ToolsNamespace.instance,
    'skills': SkillsNamespace.instance,

    // ── ℹ️ META 层 - 系统元信息和诊断 ───────────────────────────────────────────
    'meta': MetaNamespace.instance,
    'help': HelpNamespace.instance,
  };

  // ── LLM Tool Definitions ────────────────────────────────────────────────────

  bool isPawTool(String name) => name == toolName;

  Map<String, dynamic> openAITool() => {
        'type': 'function',
        'function': {
          'name': toolName,
          'description': _toolDescription,
          'parameters': _parameterSchema(),
        },
      };

  Map<String, dynamic> claudeTool() => {
        'name': toolName,
        'description': _toolDescription,
        'input_schema': _parameterSchema(),
      };

  static const String _toolDescription =
      'ShePaw built-in CLI. Namespaces: '
      '[CONTEXT] context (profile.*/memory.*/agents.* — use dot notation, e.g. context profile.query); '
      '[COMMUNICATION] chat (channels: list channels, messages: query messages); '
      '[TOOLING] tools (os.list/detail/categories | network.list/detail | config | <tool_name>.config), skills (LLM skills: list/detail); '
      '[META] meta (datetime | system.info/tools-list/tools-detail/capabilities), help (full docs). '
      'Tool config: shepaw tools web_search.config [--action get|set-key|delete-key|set-param|delete-param|set-note|delete|enable|disable] [--key k] [--value v]. '
      'Add flags={"help":""} to any call for contextual help. Run "shepaw help" for complete reference.';

  Map<String, dynamic> _parameterSchema() => {
        'type': 'object',
        'properties': {
          'namespace': {
            'type': 'string',
            'enum': _namespaces.keys.toList(),
            'description': 'Command namespace',
          },
          'subcommand': {
            'type': 'string',
            'description':
                'Subcommand for the chosen namespace. '
                'context: profile.<fields|query|write|delete> | memory.<query|write|append> | agents.<list|get|channels|messages|chat|memory-query|memory-write|cognition-query|cognition-write>; '
                'chat: channels|messages; '
                'tools: list | config | os.<list|detail|categories> | network.<list|detail> | <tool_name>.config [--action get|set-key|delete-key|set-param|delete-param|set-note|delete|enable|disable]; '
                'skills: list|detail; '
                'meta: datetime | system.<info|tools-list|tools-detail|capabilities>; '
                'help: (none, returns full docs)',
          },
          'flags': {
            'type': 'object',
            'description':
                'Command parameters as key-value pairs. '
                'Pass {"help": ""} to get help for any namespace, sub-namespace, or command. '
                'Common flags: name (tool/skill name), field (profile field), value (write value), '
                'fields (comma-separated list), key (memory key), id (agent ID), '
                'status (online|offline|all), channel (channel ID), category (tool category), '
                'limit (default 20), offset (default 0), message (chat content), '
                'keywords (comma-separated), type (memory/cognition type)',
            'additionalProperties': {'type': 'string'},
          },
        },
        'required': ['namespace'],
      };

  // ── Command Execution ────────────────────────────────────────────────────────

  /// 执行 shepaw 命令，返回 JSON 字符串结果（供 LLM tool_result 使用）
  ///
  /// [args] 命令参数（namespace / subcommand / flags）
  /// [isShe] 当前执行者是否为 She（默认 false，She 调用时传 true）
  Future<String> execute(Map<String, dynamic> args, {bool isShe = false}) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);

    LoggerService().info(
        'shepaw $namespace ${subcommand.isNotEmpty ? subcommand : ""} $flags [isShe=$isShe]',
        tag: 'Paw');

    try {
      final ns = _namespaces[namespace];
      if (ns == null) {
        return jsonEncode({
          'error': 'Unknown namespace: $namespace',
          'available': _namespaces.keys.toList(),
        });
      }

      if (namespace == 'help') {
        return jsonEncode(_buildHelpResult());
      }

      // 权限检查：全局启用 / She 专属
      final commandId = _buildCommandId(namespace, subcommand);
      final denyReason = await CliCommandConfigService.instance
          .checkPermission(commandId, isShe: isShe);
      if (denyReason != null) {
        return jsonEncode({'error': denyReason, 'command': commandId});
      }

      final result = await ns.execute(subcommand, flags);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  // ── Help ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildHelpResult() => {
        'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
        'namespace_layers': {
          'context': 'She internal state — profile, memory, agents',
          'communication': 'Real-time messaging — chat (channels + messages)',
          'tooling': 'System capabilities — tools (OS), skills (LLM)',
          'meta': 'System info — meta (datetime + system.*)',
        },
        'namespaces': {
          for (final ns in _namespaces.values)
            ns.namespace: {
              'desc': ns.description,
              ...ns.getHelp()..remove('namespace')..remove('description'),
            }
        },
        'examples': [
          // META
          'shepaw help',
          'shepaw meta datetime',
          'shepaw meta system.info',
          'shepaw meta system.capabilities',
          // CONTEXT
          'shepaw context profile.fields',
          'shepaw context profile.query',
          'shepaw context profile.write --field name --value John',
          'shepaw context memory.query --keys soul,user_info',
          'shepaw context memory.write --key soul --value "I am..."',
          'shepaw context memory.append --key long_term_memory --value "User mentioned..."',
          'shepaw context agents.list --status online',
          'shepaw context agents.get --id <agent_id>',
          'shepaw context agents.chat --id <agent_id> --message "Hello, I have a question"',
          'shepaw context agents.memory-query --id <agent_id> --limit 10',
          'shepaw context agents.cognition-query --id <agent_id>',
          // COMMUNICATION
          'shepaw chat channels',
          'shepaw chat messages --channel abc123 --limit 10',
          'shepaw chat messages --agent <agent_id> --limit 20 --offset 0',
          // TOOLING
          'shepaw tools list',
          'shepaw tools config',
          'shepaw tools os.list',
          'shepaw tools os.detail --name file_read',
          'shepaw tools os.categories --category file',
          'shepaw tools network.list',
          'shepaw tools network.detail --name web_search',
          'shepaw tools web_search.config',
          'shepaw tools web_search.config --action set-key --value sk-xxx',
          'shepaw tools web_search.config --action set-param --key timeout --value 60',
          'shepaw tools web_search.config --action disable',
          'shepaw skills list',
          'shepaw skills detail --name extract_pdf',
        ],
      };

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// 构建命令 ID（用于权限检查）
  /// 格式：namespace.subcommand（如 'context.profile.query'）
  String _buildCommandId(String namespace, String subcommand) {
    if (subcommand.isEmpty) return namespace;
    // subcommand 中的 '.' 在内部已是分隔符，保持原样
    return '$namespace.$subcommand';
  }

  Map<String, String> _parseFlags(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return {};
  }
}

import 'dart:convert';
import '../cli_base.dart';
import 'context/context_namespace.dart';
import 'chat/chat_namespace.dart';
import 'skills_namespace.dart';
import 'tools_namespace.dart';
import 'meta/meta_namespace.dart';
import 'help_namespace.dart';
import 'external_cli_namespace.dart';
import '../../services/logger_service.dart';
import '../../services/cli_command_config_service.dart';
import '../../services/cli_tool_registry.dart';

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
/// ─── 🔌 EXTERNAL 层（外部插拔式 CLI 工具）──────────────────
///   <namespace> 从 ~/shepaw/cli-tools/ 动态加载的外部工具
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

  final Map<String, CliNamespace> _namespaces = {
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

  /// 从 [CliToolRegistry] 重新加载外部 CLI 工具到命名空间注册表。
  ///
  /// 在以下时机调用：
  /// - app 启动 CliToolRegistry.initialize() 后
  /// - 工具 install / uninstall / rescan 后
  void reloadExternalTools() {
    // 移除所有旧的外部工具命名空间
    _namespaces.removeWhere((_, v) => v is ExternalCliNamespace);

    // 添加当前已加载的外部工具
    for (final tool in CliToolRegistry.instance.tools) {
      if (!_namespaces.containsKey(tool.namespace)) {
        _namespaces[tool.namespace] = ExternalCliNamespace(tool);
      }
    }

    LoggerService().info(
      'Reloaded external CLI tools: '
      '${CliToolRegistry.instance.tools.map((t) => t.namespace).join(", ")}',
      tag: 'Paw',
    );
  }

  // ── LLM Tool Definitions ────────────────────────────────────────────────────

  bool isPawTool(String name) => name == toolName;

  Map<String, dynamic> openAITool() => {
        'type': 'function',
        'function': {
          'name': toolName,
          'description': _buildToolDescription(),
          'parameters': _parameterSchema(),
        },
      };

  Map<String, dynamic> claudeTool() => {
        'name': toolName,
        'description': _buildToolDescription(),
        'input_schema': _parameterSchema(),
      };

  /// 内置 CLI 的基础描述
  static const String _builtinToolDescription =
      'ShePaw built-in CLI. Namespaces: '
      '[CONTEXT] context (profile.*/memory.*/agents.* — use dot notation, e.g. context profile.query); '
      '[COMMUNICATION] chat (channels: list channels, messages: query messages); '
      '[TOOLING] tools (os.list/detail/categories | network.list/detail | config | <tool_name>.config), skills (LLM skills: list/detail); '
      '[META] meta (datetime | system.info/tools-list/tools-detail/capabilities | cli-tools.<list|install|uninstall|rescan>), help (full docs). '
      'Tool config: shepaw tools web_search.config [--action get|set-key|delete-key|set-param|delete-param|set-note|delete|enable|disable] [--key k] [--value v]. '
      'Add flags={"help":""} to any call for contextual help. Run "shepaw help" for complete reference.';

  /// 动态生成工具描述（包含外部工具信息）
  String _buildToolDescription() {
    final suffix = CliToolRegistry.instance.toolDescriptionSuffix();
    if (suffix.isEmpty) return _builtinToolDescription;
    return '$_builtinToolDescription$suffix';
  }

  Map<String, dynamic> _parameterSchema() {
    // 动态构建 subcommand 描述（包含外部工具）
    final extSubcmdDesc = CliToolRegistry.instance.externalSubcommandDescription();
    final subcommandDesc = StringBuffer(
      'Subcommand for the chosen namespace. '
      'context: profile.<fields|query|write|delete> | memory.<query|write|append> | agents.<list|get|channels|messages|chat|memory-query|memory-write|cognition-query|cognition-write>; '
      'chat: channels|messages; '
      'tools: list | config | os.<list|detail|categories> | network.<list|detail> | <tool_name>.config [--action get|set-key|delete-key|set-param|delete-param|set-note|delete|enable|disable]; '
      'skills: list|detail; '
      'meta: datetime | system.<info|tools-list|tools-detail|capabilities> | cli-tools.<list|install|uninstall|rescan>; '
      'help: (none, returns full docs)',
    );
    if (extSubcmdDesc.isNotEmpty) {
      subcommandDesc.write('; $extSubcmdDesc');
    }

    return {
      'type': 'object',
      'properties': {
        'namespace': {
          'type': 'string',
          'enum': _namespaces.keys.toList(),
          'description': 'Command namespace',
        },
        'subcommand': {
          'type': 'string',
          'description': subcommandDesc.toString(),
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
  }

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

  Map<String, dynamic> _buildHelpResult() {
    // 分离内置和外部命名空间
    final externalNs = _namespaces.entries
        .where((e) => e.value is ExternalCliNamespace)
        .toList();

    final result = <String, dynamic>{
      'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
      'namespace_layers': {
        'context': 'She internal state — profile, memory, agents',
        'communication': 'Real-time messaging — chat (channels + messages)',
        'tooling': 'System capabilities — tools (OS), skills (LLM)',
        'meta': 'System info — meta (datetime + system.* + cli-tools.*)',
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
        'shepaw meta cli-tools.list',
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

    // 添加外部工具信息
    if (externalNs.isNotEmpty) {
      result['namespace_layers']['external'] =
          'External CLI tools installed under ~/shepaw/cli-tools/';
      result['external_tools'] = {
        for (final e in externalNs)
          e.key: {
            'description': e.value.description,
            'commands': (e.value as ExternalCliNamespace)
                .tool
                .commands
                .keys
                .toList(),
          },
      };
    }

    return result;
  }

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

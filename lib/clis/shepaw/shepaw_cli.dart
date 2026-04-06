import 'dart:convert';
import '../cli_base.dart';
import 'context/context_namespace.dart';
import '../../services/she_service.dart';
import 'chat/chat_namespace.dart';
import 'skills_namespace.dart';
import 'tools/tools_namespace.dart';
import 'os/os_cli_namespace.dart';
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
///   tools     系统工具（os.* / network.* / web.*）
///             web.search  Web 搜索（--query / --limit）
///             web.fetch   网页抓取（--url / --format / --timeout）
///             web.config  Web 工具配置管理
///   skills    已加载的 LLM 技能库（user-imported skills）
///   os        直接操作系统工具（shell/file/app/clipboard/process/macos）
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
    'os': OsCliNamespace.instance,

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
      'ShePaw built-in CLI. Use "shepaw help" to see all namespaces. '
      'Use "shepaw <namespace>" to see sub-commands. '
      'Use dot notation for nested commands (e.g. "shepaw context profile.query"). '
      'Add flags={"help":""} for detailed usage.';

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
      'Use dot notation for nested namespaces (e.g. "profile.query"). '
      'Omit to see available sub-commands for the namespace.',
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
  /// [agentId] 当前执行命令的 Agent ID（默认为 She 的 ID）
  /// [isUiOperation] 是否来自 UI 操作（UI 操作跳过权限检查，默认 false）
  Future<String> execute(
    Map<String, dynamic> args, {
    String agentId = SheService.sheId,
    bool isUiOperation = false,
  }) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);

    LoggerService().info(
        'shepaw $namespace ${subcommand.isNotEmpty ? subcommand : ""} $flags [agentId=$agentId]',
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
      // UI 操作（用户主动在界面点击执行）跳过权限检查
      if (!isUiOperation) {
        final commandId = _buildCommandId(namespace, subcommand);
        final denyReason = await CliCommandConfigService.instance
            .checkPermission(commandId, agentId: agentId);
        if (denyReason != null) {
          return jsonEncode({'error': denyReason, 'command': commandId});
        }
      }

      // 透传当前执行者的 agentId 到支持多 agent 的命名空间
      if (ns is ContextNamespace) ns.agentId = agentId;
      if (ns is ChatNamespace) ns.agentId = agentId;

      final result = await ns.execute(subcommand, flags);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  // ── Help ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildHelpResult() {
    final result = <String, dynamic>{
      'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
      'hint': 'Call "shepaw <namespace>" to see available sub-commands. '
              'Add flags={"help":""} to any command for detailed usage.',
      'namespaces': {
        for (final entry in _namespaces.entries)
          if (entry.value is! HelpNamespace)
            entry.key: entry.value.description,
      },
    };

    // 添加外部工具信息
    final externalNs = _namespaces.entries
        .where((e) => e.value is ExternalCliNamespace)
        .toList();
    if (externalNs.isNotEmpty) {
      result['external_tools'] = {
        for (final e in externalNs)
          e.key: e.value.description,
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
    // 兼容小模型将 flags 传为字符串的情况（如 "--query 你好 --limit 5"）
    if (raw is String) {
      return _parseFlagsFromString(raw);
    }
    return {};
  }

  /// 解析命令行风格的 flags 字符串
  ///
  /// 支持格式：
  ///   --key value        （标准双横线）
  ///   -key value         （单横线）
  ///   --key=value        （等号赋值）
  ///   --key              （布尔 flag，值为空字符串）
  ///
  /// 示例：
  ///   "--query 你好 --limit 5"   → {'query': '你好', 'limit': '5'}
  ///   "--url https://x.com"     → {'url': 'https://x.com'}
  ///   "--flag"                   → {'flag': ''}
  Map<String, String> _parseFlagsFromString(String raw) {
    final result = <String, String>{};
    if (raw.trim().isEmpty) return result;

    // 先尝试 JSON 对象解析（兼容 LLM 传 JSON 字符串的情况）
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}

    // 按 --key 或 -key 分割，提取 key-value 对
    // 正则：匹配 --key=value 或 --key（后面跟空格+非--开头的值）
    final tokens = raw.trim().split(RegExp(r'\s+'));
    int i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.startsWith('-')) {
        final key = token.replaceFirst(RegExp(r'^--?'), '');
        // --key=value 格式
        if (key.contains('=')) {
          final eq = key.indexOf('=');
          result[key.substring(0, eq)] = key.substring(eq + 1);
          i++;
          continue;
        }
        // --key value 格式（下一个 token 不以 - 开头）
        if (i + 1 < tokens.length && !tokens[i + 1].startsWith('-')) {
          // 收集所有连续的非-flag token 作为 value（支持带空格的值）
          final valueParts = <String>[];
          int j = i + 1;
          while (j < tokens.length && !tokens[j].startsWith('-')) {
            valueParts.add(tokens[j]);
            j++;
          }
          result[key] = valueParts.join(' ');
          i = j;
          continue;
        }
        // 布尔 flag（无值）
        result[key] = '';
        i++;
      } else {
        // 跳过非 flag token（可能是命令路径残留，如 "shepaw tools web.search"）
        i++;
      }
    }
    return result;
  }
}

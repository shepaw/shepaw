import 'dart:convert';
import '../cli_base.dart';
import 'profile/profile_namespace.dart';
import 'memory/memory_namespace.dart';
import 'agents/agents_namespace.dart';
import 'messages/messages_namespace.dart';
import 'channels_namespace.dart';
import 'skills_namespace.dart';
import 'tools_namespace.dart';
import 'datetime_namespace.dart';
import 'help_namespace.dart';
import '../../services/logger_service.dart';

/// ShepawCLI — She 专属的内嵌 CLI，替代 PawToolRegistry。
///
/// CLI 风格：
///   shepaw <namespace> [subcommand] [--flag value ...]
///
/// 命名空间：
///   profile   主人档案（user_profile 表）
///   memory    She 的记忆（she_memory 表）
///   agents    已添加的 AI 助手
///   channels  对话频道
///   messages  频道消息
///   skills    技能列表
///   tools     系统工具（OS tools）
///   datetime  当前日期与时间
///   help      顶层帮助
class ShepawCLI {
  static final ShepawCLI instance = ShepawCLI._();
  ShepawCLI._();

  static const String toolName = 'shepaw';

  /// chatSender 注入点，由 ChatService 在启动时设置
  set chatSender(IPawChatSender? sender) {
    AgentsNamespace.instance.chatSender = sender;
  }

  // ── 命名空间注册表 ───────────────────────────────────────────────────────────

  late final Map<String, CliNamespace> _namespaces = {
    'profile': ProfileNamespace.instance,
    'memory': MemoryNamespace.instance,
    'agents': AgentsNamespace.instance,
    'channels': ChannelsNamespace.instance,
    'messages': MessagesNamespace.instance,
    'skills': SkillsNamespace.instance,
    'tools': ToolsNamespace.instance,
    'datetime': DatetimeNamespace.instance,
    'help': HelpNamespace.instance,
  };

  // ── LLM Tool Definitions ────────────────────────────────────────────────────

  bool isPawTool(String name) => name == toolName;

  Map<String, dynamic> openAITool() => {
        'type': 'function',
        'function': {
          'name': toolName,
          'description':
              'ShePaw built-in CLI: query and write user profile, She memories, agent list, channel messages, and more. Run "shepaw help" for the full command list.',
          'parameters': _parameterSchema(),
        },
      };

  Map<String, dynamic> claudeTool() => {
        'name': toolName,
        'description':
            'ShePaw built-in CLI: query and write user profile, She memories, agent list, channel messages, and more. Run "shepaw help" for the full command list.',
        'input_schema': _parameterSchema(),
      };

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
                'Subcommand. profile: fields|query|write|delete; memory: query|write|append; agents: list|get|channels|messages|chat; channels: list; messages: query; skills: list; tools: list; datetime: (no subcommand, returns current time); help: (no subcommand)',
          },
          'flags': {
            'type': 'object',
            'description':
                'Command parameters as key-value pairs. Common: field (profile field name), value (value to write), fields (comma-separated field list), key (memory key), id (agent ID), status (online/offline/all), channel (channel ID), agent (agent ID for messages query), limit (count, default 20), offset (skip count, default 0), message (message content for agents chat)',
            'additionalProperties': {'type': 'string'},
          },
        },
        'required': ['namespace'],
      };

  // ── Command Execution ────────────────────────────────────────────────────────

  /// 执行 shepaw 命令，返回 JSON 字符串结果（供 LLM tool_result 使用）
  Future<String> execute(Map<String, dynamic> args) async {
    final namespace = args['namespace'] as String? ?? 'help';
    final subcommand = args['subcommand'] as String? ?? '';
    final flags = _parseFlags(args['flags']);

    LoggerService().info(
        'shepaw $namespace ${subcommand.isNotEmpty ? subcommand : ""} $flags',
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

      final result = await ns.execute(subcommand, flags);
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': e.toString()});
    }
  }

  // ── Help ─────────────────────────────────────────────────────────────────────

  Map<String, dynamic> _buildHelpResult() => {
        'cli': 'shepaw <namespace> [subcommand] [--flag value ...]',
        'namespaces': {
          for (final ns in _namespaces.values)
            ns.namespace: {
              'desc': ns.description,
              ...ns.getHelp()..remove('namespace')..remove('description'),
            }
        },
        'examples': [
          'shepaw help',
          'shepaw profile fields',
          'shepaw profile query',
          'shepaw profile write --field name --value John',
          'shepaw memory query --keys soul,user_info',
          'shepaw memory write --key soul --value "I am..."',
          'shepaw memory append --key long_term_memory --value "User mentioned..."',
          'shepaw agents list --status online',
          'shepaw agents channels --id <agent_id>',
          'shepaw agents messages --id <agent_id>',
          'shepaw agents messages --id <agent_id> --channel <channel_id> --limit 20 --offset 20',
          'shepaw agents chat --id <agent_id> --message "Hello, I have a question"',
          'shepaw messages query --channel abc123 --limit 10',
          'shepaw messages query --agent <agent_id> --limit 20 --offset 0',
          'shepaw datetime',
        ],
      };

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Map<String, String> _parseFlags(dynamic raw) {
    if (raw == null) return {};
    if (raw is Map) {
      return raw.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    return {};
  }
}

import '../../../cli_base.dart';
import '../../../../services/os_tool_registry.dart';

/// Network 工具子命名空间 - 网络与 Web 能力
///
/// 管理所有 category = 'network' 的工具：
///   web_search — 搜索引擎查询
///   web_fetch  — 抓取网页内容
///   （未来可扩展：http_request、rss_fetch 等）
///
/// Subcommands:
/// - `list`   列出所有网络工具
/// - `detail` 获取单个工具的完整参数文档（--name <tool_name>）
class NetworkSubNamespace extends CliNamespace {
  static final instance = NetworkSubNamespace._();
  NetworkSubNamespace._();

  static const _networkCategory = 'network';

  @override
  String get namespace => 'network';

  @override
  String get description => 'Network and web tools (search, fetch, http)';

  @override
  Map<String, CliCommand> get commands => {
        'list': _NetworkListCommand(),
        'detail': _NetworkDetailCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List all network tools',
          'detail': 'Full parameter docs for a tool (--name <tool_name>)',
        },
        'examples': [
          'shepaw tools network.list',
          'shepaw tools network.detail --name web_search',
          'shepaw tools network.detail --name web_fetch',
        ],
      };
}

// ── Commands ─────────────────────────────────────────────────────────────────

class _NetworkListCommand extends CliCommand {
  @override
  String get name => 'list';
  @override
  String get description => 'List all network and web tools';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {},
        'usage': 'shepaw tools network.list',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final tools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            t.category == NetworkSubNamespace._networkCategory)
        .toList();
    return {
      'platform': platform,
      'tools': tools
          .map((t) => {
                'name': t.name,
                'description': t.description,
                'risk': t.defaultRiskLevel,
              })
          .toList(),
      'count': tools.length,
    };
  }
}

class _NetworkDetailCommand extends CliCommand {
  @override
  String get name => 'detail';
  @override
  String get description => 'Get full parameter docs for a specific network tool';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'name': {
            'description': 'Network tool name to get documentation for',
            'required': true,
            'type': 'string',
          },
        },
        'usage': 'shepaw tools network.detail --name <tool_name>',
        'note': 'Use "shepaw tools network.list" to see available network tools',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name'];
    if (name == null || name.isEmpty) {
      return {
        'error': 'Missing required flag: --name',
        'usage': 'shepaw tools network.detail --name <tool_name>',
      };
    }
    final tool = OsToolRegistry.instance.tools
        .where((t) =>
            t.name == name &&
            t.category == NetworkSubNamespace._networkCategory)
        .firstOrNull;
    if (tool == null) {
      return {
        'error': 'Network tool not found: $name',
        'hint': 'Run "shepaw tools network.list" to see available network tools',
      };
    }
    return {
      'name': tool.name,
      'description': tool.description,
      'category': tool.category,
      'risk': tool.defaultRiskLevel,
      'supported_platforms': tool.supportedPlatforms.toList(),
      'parameter_schema': tool.parameterSchema,
    };
  }
}

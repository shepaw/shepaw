import '../../../cli_base.dart';
import '../../../../services/os_tool_registry.dart';
import '../../../../services/tool_config_service.dart';
import 'search_command.dart';
import 'fetch_command.dart';

/// [TOOLING 层] Web 工具子命名空间 — Web 搜索和内容抓取
///
/// 将 web 工具直接暴露在 tools 层级下，提供更简洁的访问方式。
/// 每个具体命令自己管理其配置（search.config / fetch.config）。
///
/// 扁平命令:
///   shepaw tools web.search --query "..." [--limit n]
///   shepaw tools web.fetch --url "..." [--format text|markdown|html] [--timeout n]
///   shepaw tools web.config                       — 查看所有 web 工具配置汇总
///
/// 各命令配置路由 (<name>.config):
///   shepaw tools web.search.config                — 查看 web_search 配置
///   shepaw tools web.search.config --action set-key --value BSA-xxx
///   shepaw tools web.search.config --action set-param --key max_results --value 20
///   shepaw tools web.search.config --action disable
///   shepaw tools web.fetch.config                 — 查看 web_fetch 配置
///   shepaw tools web.fetch.config --action enable
class WebSubNamespace extends CliNamespace {
  static final instance = WebSubNamespace._();
  WebSubNamespace._();

  final _searchCommand = WebSearchCommand();
  final _fetchCommand = WebFetchCommand();

  @override
  String get namespace => 'web';

  @override
  String get description =>
      'Web search and content fetching with config management';

  @override
  Map<String, CliCommand> get commands => {
        'search': _searchCommand,
        'fetch': _fetchCommand,
        'config': _WebConfigListCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'search': 'Search the web (--query <q> [--limit n])',
          'fetch':
              'Fetch URL content (--url <url> [--format text|markdown|html] [--timeout n])',
          'config': 'List configuration summary for all web tools',
          'search.config':
              'Manage web_search config (API key, params, enable/disable)',
          'fetch.config': 'Manage web_fetch config (params, enable/disable)',
        },
        'examples': [
          'shepaw tools web.search --query "Flutter state management"',
          'shepaw tools web.search --query "Dart 3 records" --limit 5',
          'shepaw tools web.fetch --url https://dart.dev',
          'shepaw tools web.fetch --url https://example.com --format text --timeout 60',
          'shepaw tools web.config',
          'shepaw tools web.search.config',
          'shepaw tools web.search.config --action set-key --value BSA-xxx',
          'shepaw tools web.search.config --action set-param --key max_results --value 20',
          'shepaw tools web.search.config --action disable',
          'shepaw tools web.fetch.config',
          'shepaw tools web.fetch.config --action enable',
        ],
      };

  // ── 动态路由：拦截 search.config / fetch.config ─────────────────────────

  @override
  Future<Map<String, dynamic>> execute(
      String subcommand, Map<String, String> flags) async {
    // 路由 search.config → WebSearchCommand.executeConfig
    if (subcommand == 'search.config') {
      return _searchCommand.executeConfig(flags);
    }

    // 路由 fetch.config → WebFetchCommand.executeConfig
    if (subcommand == 'fetch.config') {
      return _fetchCommand.executeConfig(flags);
    }

    // 其他路由照常处理（search / fetch / config / help）
    return super.execute(subcommand, flags);
  }
}

// ── Web config summary command ───────────────────────────────────────────────

class _WebConfigListCommand extends CliCommand {
  @override
  String get name => 'config';

  @override
  String get description => 'List configuration summary for all web tools';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'usage': 'shepaw tools web.config',
        'note':
            'To manage a specific tool\'s config, use: shepaw tools web.<search|fetch>.config',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final service = ToolConfigService.instance;
    final registry = OsToolRegistry.instance;

    final webTools = ['web_search', 'web_fetch'];
    final result = <Map<String, dynamic>>[];

    for (final toolName in webTools) {
      final tool = registry.tools.where((t) => t.name == toolName).firstOrNull;
      final config = await service.getToolConfig(toolName);

      result.add({
        'tool_name': toolName,
        'description': tool?.description ?? '',
        'configured': config != null,
        'enabled': config?.enabled ?? true,
        'has_api_key': config?.hasApiKey ?? false,
        'has_param_overrides': config?.parameterOverrides != null,
        'note': config?.note,
      });
    }

    return {
      'web_tools': result,
      'total': result.length,
      'configured': result.where((r) => r['configured'] == true).length,
      'hint':
          'Use "shepaw tools web.<search|fetch>.config" to manage a specific tool\'s config',
    };
  }
}

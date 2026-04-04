import '../../../cli_base.dart';
import '../../../../services/os_tool_registry.dart';
import '../../../../services/tool_config_service.dart';
import 'brave_search_command.dart';
import 'fetch_command.dart';
import 'search_command.dart';
import 'tavily_search_command.dart';

/// [TOOLING 层] Web 工具子命名空间 — Web 搜索和内容抓取
///
/// 将 web 工具直接暴露在 tools 层级下，提供更简洁的访问方式。
/// config 能力由基类 CliNamespace 统一处理，无需手动路由。
///
/// 扁平命令:
///   shepaw tools web.fetch --url "..." [--format text|markdown|html] [--timeout n]
///   shepaw tools web.config                       — 查看所有 web 工具配置汇总
///
/// search 命令（支持多个搜索引擎）:
///   shepaw tools web.search --query "..."         — 通用搜索（自动选择引擎）
///   shepaw tools web.search.brave --query "..."   — 使用 Brave 搜索
///   shepaw tools web.search.tavily --query "..."  — 使用 Tavily 搜索
///
/// 配置路由（基类自动处理 <cmd>.config 和 --config flag）:
///   shepaw tools web.search.config                — 查看/管理 web_search 通用配置
///   shepaw tools web.search.brave.config          — 查看/管理 brave_search 配置
///   shepaw tools web.search.tavily.config         — 查看/管理 tavily_search 配置
///   shepaw tools web.fetch.config                 — 查看/管理 web_fetch 配置
///   shepaw tools web.search --config              — 等价于 web.search.config（快捷方式）
class WebSubNamespace extends CliNamespace {
  static final instance = WebSubNamespace._();
  WebSubNamespace._();

  final _searchNamespace = _WebSearchNamespace();
  final _fetchCommand = WebFetchCommand();

  @override
  String get namespace => 'web';

  @override
  String get description =>
      'Web search and content fetching with config management';

  @override
  Map<String, CliCommand> get commands => {
        _fetchCommand.name: _fetchCommand,
        'config': _WebConfigListCommand(),
      };

  @override
  Map<String, CliNamespace> get subNamespaces => {
        'search': _searchNamespace,
      };
}

// ── Web Search 子命名空间（支持多个搜索引擎）──────────────────────────────────

/// `web.search.*` 子命名空间 — 支持多个搜索引擎（Brave、Tavily 等）
class _WebSearchNamespace extends CliNamespace {
  final _searchCommand = WebSearchCommand();
  final _braveCommand = BraveSearchCommand();
  final _tavilyCommand = TavilySearchCommand();

  @override
  String get namespace => 'search';

  @override
  String get description => 'Choose a search engine and execute web search';

  @override
  String get usage =>
      'shepaw tools web.search <brave|tavily> --query <query> [--limit <n>]';

  /// 所有搜索引擎命令（包括通用搜索）
  @override
  Map<String, CliCommand> get commands => {
        _searchCommand.name: _searchCommand,
        _braveCommand.name: _braveCommand,
        _tavilyCommand.name: _tavilyCommand,
        'config': _WebSearchConfigCommand(),
      };
}

// ── Web config summary command ───────────────────────────────────────────────

class _WebConfigListCommand extends CliCommand {
  @override
  String get name => 'config';

  @override
  String get description => 'List configuration summary for all web tools';

  @override
  String get usage => 'shepaw tools web.config';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final service = ToolConfigService.instance;
    final registry = OsToolRegistry.instance;

    final webTools = [
      'web_search',
      'web_fetch',
      'brave_search',
      'tavily_search',
    ];
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
      'hint': 'Use "shepaw tools web.<search|fetch>.config" or "shepaw tools web.search.<brave|tavily>.config"',
    };
  }
}

// ── Web Search Config 命令（显示 search namespace 下的配置汇总）─────────────

class _WebSearchConfigCommand extends CliCommand {
  @override
  String get name => 'config';

  @override
  String get description =>
      'List configuration summary for web search engines';

  @override
  String get usage => 'shepaw tools web.search.config';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final service = ToolConfigService.instance;

    final searchTools = ['web_search', 'brave_search', 'tavily_search'];
    final result = <Map<String, dynamic>>[];

    for (final toolName in searchTools) {
      final config = await service.getToolConfig(toolName);

      result.add({
        'tool_name': toolName,
        'configured': config != null,
        'enabled': config?.enabled ?? true,
        'has_api_key': config?.hasApiKey ?? false,
        'has_param_overrides': config?.parameterOverrides != null,
      });
    }

    return {
      'search_engines': result,
      'total': result.length,
      'configured': result.where((r) => r['configured'] == true).length,
      'hint':
          'Use "shepaw tools web.search.<brave|tavily>.config" to manage engine-specific config',
    };
  }
}

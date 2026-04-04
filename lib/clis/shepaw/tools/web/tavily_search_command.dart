import '../../../cli_base.dart';
import '../../../../models/cli_config_field.dart';
import '../../../../models/command_config_schema.dart';
import '../../../../services/network/web_search/tavily_search_provider.dart';
import '../../../../services/tool_config_service.dart';

/// `shepaw tools web.search.tavily` — 使用 Tavily Search API 进行网络搜索
///
/// 这是 web.search 命令的一个子命令实现，专门针对 Tavily Search API。
/// 配置与执行完全独立，配置值从 `tavily_search` 工具配置中读取。
///
/// Flags:
///   --query    搜索关键词（必须）
///   --limit    返回结果数量（默认 10）
///
/// 配置管理:
///   shepaw tools web.search.tavily.config
///   shepaw tools web.search.tavily.config --action set-key --value tvly-xxxxx
///   shepaw tools web.search.tavily --config       — 快捷查看配置
///
/// 示例:
///   shepaw tools web.search.tavily --query "machine learning" --limit 5
///   shepaw tools web.search.tavily --query "python async programming"
class TavilySearchCommand extends CliCommand {
  @override
  String get name => 'tavily';

  @override
  String get description =>
      'Search the web using Tavily Search API and return relevant results';

  @override
  String get usage =>
      'shepaw tools web.search.tavily --query <query> [--limit <n>]';

  @override
  CommandConfigSchema get configSchema => _schema;

  static const _schema = CommandConfigSchema(
    toolName: 'tavily_search',
    displayName: 'Tavily Search',
    description: 'API key and parameters for Tavily Search engine',
    fields: [
      CliConfigField(
        key: 'api_key',
        label: 'API Key',
        type: CliConfigFieldType.apiKey,
        required: true,
        description:
            'Your Tavily Search API key. Get one at: https://app.tavily.com. '
            'Key format: starts with "tvly-"',
      ),
      CliConfigField(
        key: 'max_results',
        label: 'Max Results',
        type: CliConfigFieldType.integer,
        description:
            'Default number of search results per query (default: 10, max: 20)',
        defaultValue: 10,
      ),
      CliConfigField(
        key: 'include_snippets',
        label: 'Include Snippets',
        type: CliConfigFieldType.boolean,
        description: 'Whether to include content snippets in results (default: true)',
        defaultValue: true,
      ),
      CliConfigField(
        key: 'timeout',
        label: 'Timeout (seconds)',
        type: CliConfigFieldType.integer,
        description: 'Request timeout in seconds (default: 30)',
        defaultValue: 30,
      ),
    ],
  );

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'query': {
        'description': 'Search query string',
        'required': true,
        'type': 'string',
      },
      'limit': {
        'description': 'Maximum number of results to return (default: 10)',
        'required': false,
        'type': 'integer',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    // 1. 验证必填参数
    final query = flags['query'];
    if (query == null || query.isEmpty) {
      return {
        'error': 'Missing required flag: --query',
        'usage': usage,
      };
    }

    // 2. 从 flags 解析 limit（CLI 参数优先）
    final limitFromFlags = int.tryParse(flags['limit'] ?? '');

    // 3. 从配置读取所有参数
    final service = ToolConfigService.instance;
    final config = await service.getToolConfig('tavily_search');
    final apiKey = await service.getToolApiKey('tavily_search');

    // 4. 验证 API Key
    if (apiKey == null || apiKey.isEmpty) {
      return {
        'error': 'Tavily Search API key not configured',
        'configured': false,
        'hint': 'Run: shepaw tools web.search.tavily.config --action set-key --value tvly-xxxxx',
      };
    }

    // 5. 构建最终参数（CLI flags > 配置值 > 默认值）
    final limit = limitFromFlags ??
        (config?.parameterOverrides?['max_results'] as int?) ??
        10;

    // 6. 执行搜索
    try {
      return await TavilySearchProvider.instance.search(query, limit, apiKey);
    } catch (e) {
      return {
        'success': false,
        'error': 'Tavily Search failed: $e',
      };
    }
  }
}

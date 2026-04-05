import '../../../cli_base.dart';
import '../../../../models/cli_config_field.dart';
import '../../../../models/command_config_schema.dart';
import '../../../../services/network/network_service.dart';

/// `shepaw tools web.search` — 执行网络搜索
///
/// 调用 WebSearchService 搜索网页，返回标题、链接和摘要。
/// API Key 由 ToolConfigService 从安全存储注入（web_search 工具配置）。
///
/// Flags:
///   --query  搜索关键词（必须）
///   --limit  返回结果数量（默认 10）
///
/// 配置（基类自动处理）:
///   shepaw tools web.search.config
///   shepaw tools web.search.config --action set-key --value YOUR_KEY
///   shepaw tools web.search.config --action set-param --key max_results --value 20
///   shepaw tools web.search --config             — 快捷查看配置
///
/// 示例:
///   shepaw tools web.search --query "Flutter state management" --limit 5
class WebSearchCommand extends CliCommand {
  @override
  String get name => 'search';

  @override
  String get description => 'Search the web and return relevant results';

  @override
  String get usage => 'shepaw tools web.search --query <query> [--limit <n>]';

  @override
  CommandConfigSchema get configSchema => _schema;

  static const _schema = CommandConfigSchema(
    toolName: 'web_search',
    displayName: 'Web Search',
    description: 'API key and parameters for the web search engine (Brave / Tavily)',
    fields: [
      CliConfigField(
        key: 'api_key',
        label: 'API Key',
        type: CliConfigFieldType.secret,
        required: true,
        description:
            'Brave Search API key (starts with BSA-) or Tavily key (starts with tvly-). '
            'The engine is auto-detected from the key prefix.',
      ),
      CliConfigField(
        key: 'max_results',
        label: 'Max Results',
        type: CliConfigFieldType.integer,
        description: 'Default number of results per query (default: 10)',
        defaultValue: 10,
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
    final query = flags['query'];
    if (query == null || query.isEmpty) {
      return {
        'error': 'Missing required flag: --query',
        'usage': usage,
      };
    }

    final limit = int.tryParse(flags['limit'] ?? '') ?? 10;

    // WebSearchService 内部已处理 API Key 获取和搜索引擎选择
    return await NetworkService.instance.webSearch.search(
      query,
      limit: limit,
    );
  }
}

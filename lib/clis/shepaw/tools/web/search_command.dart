import '../../../cli_base.dart';
import '../../../../services/network/network_service.dart';
import 'tool_config_mixin.dart';

/// `shepaw tools web.search` — 执行网络搜索
///
/// 调用 WebSearchService 搜索网页，返回标题、链接和摘要。
/// API Key 由 ToolConfigService 从安全存储注入（web_search 工具配置）。
///
/// Flags:
///   --query  搜索关键词（必须）
///   --limit  返回结果数量（默认 10）
///
/// 配置子命令（search.config）:
///   shepaw tools web.search.config
///   shepaw tools web.search.config --action set-key --value YOUR_KEY
///   shepaw tools web.search.config --action set-param --key max_results --value 20
///   shepaw tools web.search.config --action disable
///
/// 示例:
///   shepaw tools web.search --query "Flutter state management" --limit 5
class WebSearchCommand extends CliCommand with WebToolConfigMixin {
  static const _toolName = 'web_search';
  static const _shortName = 'search';

  @override
  String get name => _shortName;

  @override
  String get description => 'Search the web and return relevant results';

  @override
  String get usage => 'shepaw tools web.search --query <query> [--limit <n>]';

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
    base['config_hint'] =
        'API Key is required. Set via: shepaw tools web.search.config --action set-key --value YOUR_KEY';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final query = flags['query'];
    if (query == null || query.isEmpty) {
      return {
        'error': 'Missing required flag: --query',
        'usage': 'shepaw tools web.search --query <query> [--limit <n>]',
      };
    }

    final limit = int.tryParse(flags['limit'] ?? '') ?? 10;

    // WebSearchService 内部已处理 API Key 获取和搜索引擎选择
    return await NetworkService.instance.webSearch.search(
      query,
      limit: limit,
    );
  }

  /// 处理 `search.config` 子命令（由 WebSubNamespace 路由调用）
  Future<Map<String, dynamic>> executeConfig(
          Map<String, String> flags) =>
      handleConfig(_toolName, _shortName, flags);
}

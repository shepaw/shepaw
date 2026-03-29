/// Web Search 服务 - 网络搜索能力
/// 
/// 支持 Brave Search 和 Tavily Search 两个搜索引擎
/// 通过 API Key 前缀自动检测使用哪个搜索引擎
library;

import '../../tool_config_service.dart';
import 'brave_search_provider.dart';
import 'tavily_search_provider.dart';

class WebSearchService {
  static final WebSearchService _instance = WebSearchService._();
  
  WebSearchService._();
  
  static WebSearchService get instance => _instance;

  /// 执行网络搜索
  /// 
  /// 参数：
  ///   - query: 搜索关键词
  ///   - limit: 返回结果数量（默认 10）
  /// 
  /// 返回：{success: bool, engine: string, query: string, count: int, results: [...]}
  /// 
  /// 搜索引擎自动选择：
  ///   - Tavily: 如果 API Key 以 tvly- 开头或包含 tavily
  ///   - Brave: 其他情况
  Future<Map<String, dynamic>> search(String query, {int limit = 10}) async {
    // 验证查询词
    if (query.isEmpty) {
      return {
        'success': false,
        'error': 'Search query cannot be empty',
      };
    }

    try {
      // 获取已配置的 API Key
      final apiKey =
          await ToolConfigService.instance.getToolApiKey('web_search');
      if (apiKey == null || apiKey.isEmpty) {
        return {
          'success': false,
          'error': 'Web search API key not configured. '
              'Please set it using: shepaw tools web_search.config --action set-key --value YOUR_KEY',
        };
      }

      // 根据 API Key 格式自动选择搜索引擎
      final isTavily = apiKey.startsWith('tvly-') || apiKey.contains('tavily');

      if (isTavily) {
        return await TavilySearchProvider.instance.search(query, limit, apiKey);
      } else {
        return await BraveSearchProvider.instance.search(query, limit, apiKey);
      }
    } catch (e) {
      return {
        'success': false,
        'error': 'Web search failed: $e',
      };
    }
  }
}

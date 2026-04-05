/// Web Search 服务 - 网络搜索能力
/// 
/// 支持多个搜索引擎，优先级如下：
/// 1. 外部 CLI 工具（via CliToolRegistry，如 brave-search）
/// 2. 内置提供者（Brave Search、Tavily Search）
/// 
/// 引擎自动选择：
///   - 如果已安装 brave-search CLI 工具，使用它（可插拔）
///   - 否则，根据 API Key 前缀：
///     - Tavily: API Key 以 tvly- 开头或包含 tavily
///     - Brave: 其他情况
library;

import '../../cli_tool_registry.dart';
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
  Future<Map<String, dynamic>> search(String query, {int limit = 10}) async {
    // 验证查询词
    if (query.isEmpty) {
      return {
        'success': false,
        'error': 'Search query cannot be empty',
      };
    }

    try {
      // 获取已配置的 secret
      final apiKey =
          await ToolConfigService.instance.getToolSecret('web_search', 'api_key');
      if (apiKey == null || apiKey.isEmpty) {
        return {
          'success': false,
          'error': 'Web search API key not configured. '
              'Please set it using: shepaw tools web.search.config --action set --key api_key --value YOUR_KEY',
        };
      }

      // 优先尝试外部 CLI 工具（brave-search）
      final externalResult = 
          await _tryExternalCliTool('brave-search', query, limit, apiKey);
      if (externalResult != null) {
        return externalResult;
      }

      // 后备方案：使用内置提供者
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

  /// 尝试通过外部 CLI 工具执行搜索
  /// 
  /// 返回执行结果，如果工具未安装或执行失败则返回 null
  Future<Map<String, dynamic>?> _tryExternalCliTool(
    String toolNamespace,
    String query,
    int limit,
    String apiKey,
  ) async {
    try {
      final registry = CliToolRegistry.instance;
      
      // 查找工具定义
      final tool = registry.getDefinition(toolNamespace);
      if (tool == null) {
        // 工具未安装，返回 null 让后备方案处理
        return null;
      }

      // 通过 CliToolRegistry 执行命令
      final result = await registry.executeCommand(
        toolNamespace,
        'search',
        {
          'query': query,
          'limit': limit.toString(),
          'apiKey': apiKey,
        },
      );

      // 检查执行结果
      if (result.containsKey('error')) {
        // 工具返回错误
        return {
          'success': false,
          'error': result['error'] ?? 'Unknown error from $toolNamespace',
        };
      }

      // 检查 data 字段
      final data = result['data'] as Map<String, dynamic>?;
      if (data == null) {
        // 无有效的响应数据
        return null;
      }

      // 成功响应
      return {
        'success': true,
        'engine': data['engine'] ?? toolNamespace,
        'query': data['query'] ?? query,
        'count': (data['count'] as num?)?.toInt() ?? 0,
        'results': data['results'] as List<dynamic>? ?? [],
      };
    } catch (e) {
      // 执行失败，返回 null 让后备方案处理
      return null;
    }
  }
}

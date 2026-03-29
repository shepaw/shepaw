/// Tavily Search API 提供者
library;

import 'dart:convert';

import '../../../utils/http_client.dart';

class TavilySearchProvider {
  static final TavilySearchProvider _instance = TavilySearchProvider._();
  
  TavilySearchProvider._();
  
  static TavilySearchProvider get instance => _instance;

  /// 使用 Tavily Search API 进行搜索
  /// 
  /// 参数：
  ///   - query: 搜索关键词
  ///   - limit: 返回结果数量
  ///   - apiKey: Tavily API Key
  /// 
  /// 返回：{success: bool, engine: 'Tavily Search', query: string, count: int, results: [...]}
  Future<Map<String, dynamic>> search(
    String query,
    int limit,
    String apiKey,
  ) async {
    try {
      final client = HttpClientWrapper();
      final url = Uri.https('api.tavily.com', '/search');

      final requestBody = {
        'api_key': apiKey,
        'query': query,
        'max_results': limit,
        'include_snippets': true,
      };

      final response = await client.post(
        url,
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(requestBody),
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'Tavily Search API error (${response.statusCode})',
        };
      }

      final data = jsonDecode(response.body);
      final results = (data['results'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      final formattedResults = results.take(limit).map((r) {
        return {
          'title': r['title'] ?? '',
          'link': r['url'] ?? '',
          'snippet': r['snippet'] ?? '',
        };
      }).toList();

      return {
        'success': true,
        'engine': 'Tavily Search',
        'query': query,
        'count': formattedResults.length,
        'results': formattedResults,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Tavily Search error: $e',
      };
    }
  }
}

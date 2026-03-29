/// Brave Search API 提供者
library;

import 'dart:convert';

import '../../../utils/http_client.dart';

class BraveSearchProvider {
  static final BraveSearchProvider _instance = BraveSearchProvider._();
  
  BraveSearchProvider._();
  
  static BraveSearchProvider get instance => _instance;

  /// 使用 Brave Search API 进行搜索
  /// 
  /// 参数：
  ///   - query: 搜索关键词
  ///   - limit: 返回结果数量
  ///   - apiKey: Brave Search API Key
  /// 
  /// 返回：{success: bool, engine: 'Brave Search', query: string, count: int, results: [...]}
  Future<Map<String, dynamic>> search(
    String query,
    int limit,
    String apiKey,
  ) async {
    try {
      final client = HttpClientWrapper();
      final url = Uri.https('api.search.brave.com', '/res/v1/web/search', {
        'q': query,
        'count': limit.toString(),
      });

      final response = await client.get(
        url,
        headers: {
          'Accept': 'application/json',
          'X-Subscription-Token': apiKey,
        },
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'Brave Search API error (${response.statusCode})',
        };
      }

      final data = jsonDecode(response.body);
      final results = (data['web'] as List?)?.cast<Map<String, dynamic>>() ?? [];

      final formattedResults = results.take(limit).map((r) {
        return {
          'title': r['title'] ?? '',
          'link': r['url'] ?? '',
          'snippet': r['description'] ?? '',
        };
      }).toList();

      return {
        'success': true,
        'engine': 'Brave Search',
        'query': query,
        'count': formattedResults.length,
        'results': formattedResults,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Brave Search error: $e',
      };
    }
  }
}

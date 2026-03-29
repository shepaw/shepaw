/// Web Fetch 服务 - 获取网页内容并转换为指定格式
/// 
/// 支持格式：text（纯文本）、html（原始HTML）、markdown（Markdown）
library;

import 'dart:convert';

import '../../../utils/http_client.dart';
import 'html_converter.dart';
import 'url_validator.dart';

const _maxOutputSize = 10 * 1024; // 10 KB

class WebFetchService {
  static final WebFetchService _instance = WebFetchService._();
  
  WebFetchService._();
  
  static WebFetchService get instance => _instance;

  /// 获取网页内容
  /// 
  /// 参数：
  ///   - url: 网页 URL
  ///   - format: 输出格式 (text/html/markdown，默认 markdown)
  ///   - timeoutSecs: 请求超时时间（秒，默认 30，范围 1-300）
  /// 
  /// 返回：{success: bool, url: string, format: string, content: string}
  Future<Map<String, dynamic>> fetchContent(
    String url, {
    String format = 'markdown',
    int timeoutSecs = 30,
  }) async {
    // 验证参数
    if (url.isEmpty) {
      return {'success': false, 'error': 'URL cannot be empty'};
    }

    if (!['text', 'html', 'markdown'].contains(format)) {
      return {
        'success': false,
        'error': 'Invalid format: $format. Must be: text, html, or markdown',
      };
    }

    try {
      // 验证并规范化 URL
      final uri = parseAndValidateUrl(url);
      if (uri == null) {
        return {'success': false, 'error': 'Invalid URL: $url'};
      }

      // 发送 HTTP 请求
      final client = HttpClientWrapper(
        timeout: Duration(seconds: timeoutSecs.clamp(1, 300)),
      );

      final response = await client.get(
        uri,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        },
      );

      if (response.statusCode != 200) {
        return {
          'success': false,
          'error': 'Failed to fetch URL (HTTP ${response.statusCode})',
        };
      }

      // 检查内容类型
      final contentType = response.headers['content-type'] ?? 'text/html';
      final isHtml = contentType.contains('text/html');
      final isJson = contentType.contains('application/json');

      // 获取内容
      String content = response.body;

      // 截断过长内容
      if (content.length > _maxOutputSize) {
        content = truncateOutput(content, _maxOutputSize);
      }

      // 格式转换
      switch (format) {
        case 'text':
          if (isHtml) {
            content = htmlToPlainText(content);
          } else if (isJson) {
            try {
              final decoded = jsonDecode(content);
              content = const JsonEncoder.withIndent('  ').convert(decoded);
            } catch (_) {
              // 保持原始内容
            }
          }
          break;

        case 'markdown':
          if (isHtml) {
            content = htmlToMarkdown(content);
          }
          break;

        case 'html':
          // 保持原始 HTML
          break;
      }

      return {
        'success': true,
        'url': url,
        'format': format,
        'content': content,
      };
    } catch (e) {
      return {'success': false, 'error': 'Failed to fetch URL: $e'};
    }
  }
}

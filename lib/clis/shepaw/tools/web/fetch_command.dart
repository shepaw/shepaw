import '../../../cli_base.dart';
import '../../../../services/network/network_service.dart';
import 'tool_config_mixin.dart';

/// `shepaw tools web.fetch` — 抓取网页内容
///
/// 调用 WebFetchService 获取指定 URL 的内容，支持 text / markdown / html 格式。
///
/// Flags:
///   --url      目标网页 URL（必须）
///   --format   输出格式：text | markdown | html（默认 markdown）
///   --timeout  请求超时秒数（默认 30，范围 1-300）
///
/// 配置子命令（fetch.config）:
///   shepaw tools web.fetch.config
///   shepaw tools web.fetch.config --action set-param --key timeout --value 60
///   shepaw tools web.fetch.config --action enable
///
/// 示例:
///   shepaw tools web.fetch --url https://example.com
///   shepaw tools web.fetch --url https://example.com --format text --timeout 60
class WebFetchCommand extends CliCommand with WebToolConfigMixin {
  static const _toolName = 'web_fetch';
  static const _shortName = 'fetch';

  @override
  String get name => _shortName;

  @override
  String get description => 'Fetch a URL and return content as text or markdown';

  @override
  String get usage => 'shepaw tools web.fetch --url <url> [--format <format>] [--timeout <secs>]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'url': {
        'description': 'The URL to fetch',
        'required': true,
        'type': 'string',
      },
      'format': {
        'description':
            'Output format: text, markdown, or html (default: markdown)',
        'required': false,
        'type': 'string',
        'enum': ['text', 'markdown', 'html'],
      },
      'timeout': {
        'description':
            'Request timeout in seconds (default: 30, range: 1-300)',
        'required': false,
        'type': 'integer',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final url = flags['url'];
    if (url == null || url.isEmpty) {
      return {
        'error': 'Missing required flag: --url',
        'usage':
            'shepaw tools web.fetch --url <url> [--format <format>] [--timeout <secs>]',
      };
    }

    final format = flags['format'] ?? 'markdown';
    final timeoutSecs = int.tryParse(flags['timeout'] ?? '') ?? 30;

    return await NetworkService.instance.webFetch.fetchContent(
      url,
      format: format,
      timeoutSecs: timeoutSecs,
    );
  }

  /// 处理 `fetch.config` 子命令（由 WebSubNamespace 路由调用）
  Future<Map<String, dynamic>> executeConfig(
          Map<String, String> flags) =>
      handleConfig(_toolName, _shortName, flags);
}

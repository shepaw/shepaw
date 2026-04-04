import '../../../cli_base.dart';
import '../../../../models/cli_config_field.dart';
import '../../../../models/command_config_schema.dart';
import '../../../../services/network/network_service.dart';

/// `shepaw tools web.fetch` — 抓取网页内容
///
/// 调用 WebFetchService 获取指定 URL 的内容，支持 text / markdown / html 格式。
///
/// Flags:
///   --url      目标网页 URL（必须）
///   --format   输出格式：text | markdown | html（默认 markdown）
///   --timeout  请求超时秒数（默认 30，范围 1-300）
///
/// 配置（基类自动处理）:
///   shepaw tools web.fetch.config
///   shepaw tools web.fetch.config --action set-param --key timeout --value 60
///   shepaw tools web.fetch --config              — 快捷查看配置
///
/// 示例:
///   shepaw tools web.fetch --url https://example.com
///   shepaw tools web.fetch --url https://example.com --format text --timeout 60
class WebFetchCommand extends CliCommand {
  @override
  String get name => 'fetch';

  @override
  String get description => 'Fetch a URL and return content as text or markdown';

  @override
  String get usage =>
      'shepaw tools web.fetch --url <url> [--format <format>] [--timeout <secs>]';

  @override
  CommandConfigSchema get configSchema => _schema;

  static const _schema = CommandConfigSchema(
    toolName: 'web_fetch',
    displayName: 'Web Fetch',
    description: 'Parameters for the web content fetcher',
    fields: [
      CliConfigField(
        key: 'timeout',
        label: 'Timeout (seconds)',
        type: CliConfigFieldType.integer,
        description: 'Default request timeout in seconds (default: 30)',
        defaultValue: 30,
      ),
      CliConfigField(
        key: 'format',
        label: 'Default Format',
        type: CliConfigFieldType.select,
        description: 'Default output format when --format flag is not specified',
        defaultValue: 'markdown',
        options: ['text', 'markdown', 'html'],
      ),
    ],
  );

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
        'usage': usage,
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
}

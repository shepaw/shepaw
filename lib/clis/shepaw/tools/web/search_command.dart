import '../../../cli_base.dart';
import 'brave_search_command.dart';
import 'tavily_search_command.dart';

/// `shepaw tools web.search` — 通用网络搜索命令（自动选择搜索引擎）
///
/// 当用户运行 `shepaw tools web.search --query "keyword"` 时，自动选择
/// 可用的搜索引擎（Brave 或 Tavily），并将参数透传给所选引擎。
///
/// 优先级顺序（按配置的可用性）：
/// 1. Brave Search（如果已配置 API key）
/// 2. Tavily Search（如果已配置 API key）
/// 3. 如果两者都未配置，返回错误提示
///
/// Flags:
///   --query    搜索关键词（必须）
///   --limit    返回结果数量（默认 10）
///
/// 示例:
///   shepaw tools web.search --query "flutter best practices"
///   shepaw tools web.search --query "machine learning" --limit 5
///
/// 注意：
/// - 若要明确指定搜索引擎，使用：
///   shepaw tools web.search.brave --query "..."
///   shepaw tools web.search.tavily --query "..."
/// - 若要配置搜索引擎 API key，使用：
///   shepaw tools web.search.<brave|tavily>.config
class WebSearchCommand extends CliCommand {
  static final _braveCommand = BraveSearchCommand();
  static final _tavilyCommand = TavilySearchCommand();

  @override
  String get name => 'search';

  @override
  String get description =>
      'Search the web using available search engines (automatically selects Brave or Tavily)';

  @override
  String get usage =>
      'shepaw tools web.search --query <query> [--limit <n>]';

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
    base['note'] =
        'Automatically selects the first available search engine (Brave > Tavily). '
        'To use a specific engine, use web.search.brave or web.search.tavily.';
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

    // 2. 检查可用的搜索引擎（按优先级）
    final (braveAvailable, braveReason) =
        await _braveCommand.checkAvailability();
    final (tavilyAvailable, tavilyReason) =
        await _tavilyCommand.checkAvailability();

    // 3. 选择可用的搜索引擎（优先级：Brave > Tavily）
    CliCommand selectedCommand;
    String selectedEngine;

    if (braveAvailable) {
      selectedCommand = _braveCommand;
      selectedEngine = 'Brave Search';
    } else if (tavilyAvailable) {
      selectedCommand = _tavilyCommand;
      selectedEngine = 'Tavily Search';
    } else {
      // 两个都不可用
      return {
        'error': 'No search engine configured',
        'configured': false,
        'engines': {
          'brave': {
            'available': false,
            'reason': braveReason,
          },
          'tavily': {
            'available': false,
            'reason': tavilyReason,
          },
        },
        'hint':
            'Configure at least one search engine:\n'
            '  Brave: shepaw tools web.search.brave.config --action set --key api_key --value BSA-xxxxx\n'
            '  Tavily: shepaw tools web.search.tavily.config --action set --key api_key --value tvly-xxxxx',
      };
    }

    // 4. 透传参数给选中的引擎并执行
    try {
      final result = await selectedCommand.execute(flags);
      // 在结果中标注使用了哪个引擎
      return {
        ...result,
        'engine_used': selectedEngine,
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'Search failed: $e',
        'engine_used': selectedEngine,
      };
    }
  }
}

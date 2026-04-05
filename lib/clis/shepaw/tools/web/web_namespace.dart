import '../../../cli_base.dart';
import 'brave_search_command.dart';
import 'fetch_command.dart';
import 'search_command.dart';
import 'tavily_search_command.dart';

/// [TOOLING 层] Web 工具子命名空间 — Web 搜索和内容抓取
///
/// 命令路由:
///   shepaw tools web.fetch --url "..." [--format text|markdown|html] [--timeout n]
///   shepaw tools web.search --query "..."         — 通用搜索（自动选择引擎）
///   shepaw tools web.search.brave --query "..."   — 使用 Brave 搜索
///   shepaw tools web.search.tavily --query "..."  — 使用 Tavily 搜索
///
/// 配置路由（基类自动处理 <cmd>.config 和 --config flag）:
///   shepaw tools web.fetch.config                 — 查看/管理 web_fetch 配置
///   shepaw tools web.search.config                — 查看/管理 web_search 配置
///   shepaw tools web.search.brave.config          — 查看/管理 brave_search 配置
///   shepaw tools web.search.tavily.config         — 查看/管理 tavily_search 配置
///   shepaw tools web.fetch --config               — 等价于 web.fetch.config（快捷方式）
class WebSubNamespace extends CliNamespace {
  static final instance = WebSubNamespace._();
  WebSubNamespace._();

  final _searchCommand = WebSearchCommand();
  final _braveCommand = BraveSearchCommand();
  final _tavilyCommand = TavilySearchCommand();
  final _fetchCommand = WebFetchCommand();

  @override
  String get namespace => 'web';

  @override
  String get description =>
      'Web search (Brave/Tavily) and URL content fetching';
  
  @override
  String get usage =>
      'shepaw tools web.search <brave|tavily> --query <query> [--limit <n>]';

  @override
  Map<String, CliCommand> get commands => {
        _fetchCommand.name: _fetchCommand,
        _searchCommand.name: _searchCommand,
        _braveCommand.name: _braveCommand,
        _tavilyCommand.name: _tavilyCommand,
      };
}

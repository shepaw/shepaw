import '../cli_base.dart';
import 'tools/network/network_namespace.dart';
import 'tools/web/web_namespace.dart';

/// [TOOLING 层] tools 命名空间 - Web 工具 + 工具配置管理
///
/// 子命名空间：
///   network — 网络工具分类（list/detail 查询）
///   web     — Web 搜索和抓取（search/fetch + 配置管理）
///
/// 注：OS 本地工具已独立为顶层 `os` 命名空间，使用 `shepaw os.*`
///
/// 使用分层路由，subcommand 格式为 `<sub-namespace>.<action>`：
///   shepaw tools network.list
///   shepaw tools network.detail --name web_search
///   shepaw tools web.search --query "..." [--limit n]
///   shepaw tools web.fetch --url "..." [--format ...] [--timeout n]
///   shepaw tools web.config                         — 查看所有 web 工具配置
///   shepaw tools web.search.config                  — 管理 web_search 配置
///   shepaw tools web.fetch.config                   — 管理 web_fetch 配置
///   shepaw tools web.search --config                — 快捷查看 web_search 配置
///
/// 顶层扁平命令：
///   shepaw tools list   — 列出所有网络/web 工具
///
/// config 能力由基类 CliNamespace 统一处理（与 help 对称）：
///   - `<cmd>.config` 子命令 → 对应命令的 handleConfig()
///   - `--config` flag       → 对应命令的 getConfig()
class ToolsNamespace extends CliNamespace {
  static final instance = ToolsNamespace._();
  ToolsNamespace._();

  @override
  String get namespace => 'tools';

  @override
  String get description => 'Tool management center — network tools, web search & fetch';

  @override
  String get usage => 'shepaw tools <sub-namespace>.<action> [flags]';

  /// 分层 sub-namespace
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'network': NetworkSubNamespace.instance,
        'web': WebSubNamespace.instance,
      };
}
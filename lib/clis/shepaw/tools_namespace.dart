import '../cli_base.dart';
import '../../services/os_tool_registry.dart';
import '../../services/tool_config_service.dart';
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
  String get description => 'Network and web tools — search, fetch, config management';

  @override
  String get usage => 'shepaw tools <sub-namespace>.<action> [flags]';

  /// 顶层扁平命令：跨分类汇总列表 + 配置汇总
  @override
  Map<String, CliCommand> get commands => {
        'list': _ToolsAllListCommand(),
        'config': _ToolsConfigListCommand(),
      };

  /// 分层 sub-namespace
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'network': NetworkSubNamespace.instance,
        'web': WebSubNamespace.instance,
      };
}

// ── Top-level all-tools list ─────────────────────────────────────────────────

class _ToolsAllListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all network/web tools';

  @override
  String get usage => 'shepaw tools list';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    // 只列 network 分类的工具（OS 工具已移至顶层 os 命名空间）
    final tools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            t.category == 'network')
        .toList();

    return {
      'platform': platform,
      'tools': tools.map((t) => {
        'name': t.name,
        'description': t.description,
        'category': t.category,
        'risk': t.defaultRiskLevel,
      }).toList(),
      'total_count': tools.length,
      'note': 'OS tools are at top-level namespace. Use: shepaw os list',
    };
  }
}

// ── Tool config list (summary across all tools) ───────────────────────────────

class _ToolsConfigListCommand extends CliCommand {
  @override
  String get name => 'config';

  @override
  String get description => 'List configuration summary for all tools';

  @override
  String get usage => 'shepaw tools config';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final service = ToolConfigService.instance;
    final platform = registry.currentPlatform;

    // 只列 network 分类工具（OS 工具已移至顶层 os 命名空间）
    final networkTools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            t.category == 'network')
        .toList();

    final allConfigs = await service.getAllToolConfigs();
    final configMap = {
      for (final c in allConfigs) c.toolName: c,
    };

    final result = networkTools.map((t) {
      final config = configMap[t.name];
      return {
        'tool_name': t.name,
        'category': t.category,
        'configured': config != null,
        'enabled': config?.enabled ?? true,
        'has_api_key': config?.hasApiKey ?? false,
        'has_param_overrides': config?.parameterOverrides != null,
        'note': config?.note,
      };
    }).toList();

    final configuredCount = result.where((r) => r['configured'] == true).length;

    return {
      'platform': platform,
      'total_tools': networkTools.length,
      'configured_tools': configuredCount,
      'tools': result,
      'hint': 'Use "shepaw tools web.<cmd> --config" or "shepaw tools web.<cmd>.config" to manage',
    };
  }
}

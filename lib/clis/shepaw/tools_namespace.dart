import '../cli_base.dart';
import '../../services/os_tool_registry.dart';
import 'tools/os/os_namespace.dart';
import 'tools/network/network_namespace.dart';

/// [TOOLING 层] tools 命名空间 - 系统工具总入口
///
/// 按工具类型分为两个子命名空间：
///
///   os      — 本地系统执行能力（file/command/process/app/clipboard）
///   network — 网络与 Web 能力（web_search/web_fetch/http_request）
///
/// 使用分层路由，subcommand 格式为 `<sub-namespace>.<action>`：
///   shepaw tools os.list
///   shepaw tools os.detail --name file_read
///   shepaw tools os.categories --category file
///   shepaw tools network.list
///   shepaw tools network.detail --name web_search
///
/// 顶层扁平命令（跨分类汇总）：
///   shepaw tools list   — 列出所有工具（os + network）
class ToolsNamespace extends CliNamespace {
  static final instance = ToolsNamespace._();
  ToolsNamespace._();

  @override
  String get namespace => 'tools';

  @override
  String get description => 'System tools — os (local) and network (web)';

  /// 顶层扁平命令：跨分类汇总列表
  @override
  Map<String, CliCommand> get commands => {
        'list': _ToolsAllListCommand(),
      };

  /// 分层 sub-namespace
  @override
  Map<String, CliNamespace> get subNamespaces => {
        'os': OsSubNamespace.instance,
        'network': NetworkSubNamespace.instance,
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List all tools across all categories (os + network)',
          'os.list': 'List OS tools on the current platform',
          'os.detail': 'Full docs for an OS tool (--name <tool_name>)',
          'os.categories': 'Browse OS tools by category (optional --category)',
          'network.list': 'List network and web tools',
          'network.detail': 'Full docs for a network tool (--name <tool_name>)',
        },
        'examples': [
          'shepaw tools list',
          'shepaw tools os.list',
          'shepaw tools os.detail --name file_read',
          'shepaw tools os.categories --category file',
          'shepaw tools network.list',
          'shepaw tools network.detail --name web_search',
        ],
      };
}

// ── Top-level all-tools list ─────────────────────────────────────────────────

class _ToolsAllListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all tools across all categories';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final tools = registry.tools
        .where((t) => t.supportedPlatforms.contains(platform))
        .toList();

    // 按 sub-namespace 分组
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in tools) {
      final ns = t.category == 'network' ? 'network' : 'os';
      grouped.putIfAbsent(ns, () => []).add({
        'name': t.name,
        'description': t.description,
        'category': t.category,
        'risk': t.defaultRiskLevel,
      });
    }

    return {
      'platform': platform,
      'tools_by_namespace': grouped,
      'total_count': tools.length,
    };
  }
}

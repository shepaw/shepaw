import '../cli_base.dart';
import '../../services/os_tool_registry.dart';

/// tools 命名空间 - 列出当前平台可用的系统工具
class ToolsNamespace extends CliNamespace {
  static final instance = ToolsNamespace._();
  ToolsNamespace._();

  @override
  String get namespace => 'tools';

  @override
  String get description => 'System tools available on current platform';

  @override
  Map<String, CliCommand> get commands => {};

  /// tools 没有子命令，直接执行
  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final tools = registry.tools
        .where((t) => t.supportedPlatforms.contains(platform))
        .toList();
    final list = tools.map((t) => {
          'name': t.name,
          'description': t.description,
          'category': t.category,
          'risk': t.defaultRiskLevel,
        }).toList();
    return {'platform': platform, 'tools': list, 'count': list.length};
  }

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {'list': 'List tools for current platform'},
    'examples': ['shepaw tools'],
  };
}

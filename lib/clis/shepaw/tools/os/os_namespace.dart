import '../../../cli_base.dart';
import '../../../../services/os_tool_registry.dart';

/// OS 工具子命名空间 - 本地系统执行能力
///
/// 涵盖现有所有非 network 分类的工具：
///   command  — shell 命令、系统信息
///   file     — 文件读写、删除、移动、列目录
///   app      — 应用与浏览器控制
///   clipboard— 剪贴板读写
///   process  — 进程管理、网络连接
///   macos    — macOS 专属工具
///
/// Subcommands:
/// - `list`       列出当前平台所有 OS 工具（不含 network）
/// - `detail`     获取单个工具的完整参数文档（--name <tool_name>）
/// - `categories` 按分类浏览（可选 --category <name>）
class OsSubNamespace extends CliNamespace {
  static final instance = OsSubNamespace._();
  OsSubNamespace._();

  /// network 以外的所有 OS 分类
  static const _osCategories = {
    'command', 'file', 'app', 'clipboard', 'process', 'macos'
  };

  @override
  String get namespace => 'os';

  @override
  String get description => 'Local OS tools (file, command, process, app, clipboard)';

  @override
  Map<String, CliCommand> get commands => {
        'list': _OsListCommand(),
        'detail': _OsDetailCommand(),
        'categories': _OsCategoriesCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List all OS tools on the current platform',
          'detail': 'Full parameter docs for a tool (--name <tool_name>)',
          'categories':
              'Browse OS tools by category (optional --category <name>)',
        },
        'available_categories': _osCategories.toList(),
        'examples': [
          'shepaw tools os.list',
          'shepaw tools os.detail --name file_read',
          'shepaw tools os.categories',
          'shepaw tools os.categories --category file',
        ],
      };
}

// ── Commands ─────────────────────────────────────────────────────────────────

class _OsListCommand extends CliCommand {
  @override
  String get name => 'list';
  @override
  String get description => 'List all OS tools available on current platform';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {},
        'usage': 'shepaw tools os.list',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final tools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            OsSubNamespace._osCategories.contains(t.category))
        .toList();
    return {
      'platform': platform,
      'tools': tools
          .map((t) => {
                'name': t.name,
                'description': t.description,
                'category': t.category,
                'risk': t.defaultRiskLevel,
              })
          .toList(),
      'count': tools.length,
    };
  }
}

class _OsDetailCommand extends CliCommand {
  @override
  String get name => 'detail';
  @override
  String get description => 'Get full parameter docs for a specific OS tool';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'name': {
            'description': 'OS tool name to get documentation for',
            'required': true,
            'type': 'string',
          },
        },
        'usage': 'shepaw tools os.detail --name <tool_name>',
        'note': 'Use "shepaw tools os.list" to see available OS tools',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name'];
    if (name == null || name.isEmpty) {
      return {
        'error': 'Missing required flag: --name',
        'usage': 'shepaw tools os.detail --name <tool_name>',
      };
    }
    final tool = OsToolRegistry.instance.tools
        .where((t) =>
            t.name == name && OsSubNamespace._osCategories.contains(t.category))
        .firstOrNull;
    if (tool == null) {
      return {
        'error': 'OS tool not found: $name',
        'hint': 'Run "shepaw tools os.list" to see available OS tools',
      };
    }
    return {
      'name': tool.name,
      'description': tool.description,
      'category': tool.category,
      'risk': tool.defaultRiskLevel,
      'supported_platforms': tool.supportedPlatforms.toList(),
      'parameter_schema': tool.parameterSchema,
    };
  }
}

class _OsCategoriesCommand extends CliCommand {
  @override
  String get name => 'categories';
  @override
  String get description => 'Browse OS tools by category';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'category': {
            'description': 'Filter by category (omit to list all categories)',
            'required': false,
            'type': 'string',
            'enum': ['command', 'file', 'app', 'clipboard', 'process', 'macos'],
          },
        },
        'usage': 'shepaw tools os.categories [--category file|command|app|...]',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = registry.currentPlatform;
    final filterCategory = flags['category'];

    final tools = registry.tools
        .where((t) =>
            t.supportedPlatforms.contains(platform) &&
            OsSubNamespace._osCategories.contains(t.category) &&
            (filterCategory == null || t.category == filterCategory))
        .toList();

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in tools) {
      grouped.putIfAbsent(t.category, () => []).add({
        'name': t.name,
        'description': t.description,
        'risk': t.defaultRiskLevel,
      });
    }

    return {
      'platform': platform,
      if (filterCategory != null) 'filter_category': filterCategory,
      'categories': grouped,
      'total_count': tools.length,
    };
  }
}

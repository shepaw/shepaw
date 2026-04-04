import 'dart:io' show Platform;

import '../../cli_base.dart';
import '../../../services/os_tool_registry.dart';
import '../../../services/os_tool_executor.dart' as os_exec;

/// [TOOLING 层] os 命名空间 — 本地操作系统工具
///
/// 将 OsToolRegistry 中定义的所有 OS 工具（非 network 类）暴露为 CLI 命令。
/// 按 category 分组为 sub-namespace，使用分层路由：
///
///   shepaw os shell.exec --command "ls -la"
///   shepaw os file.read --path /tmp/test.txt
///   shepaw os file.write --path /tmp/test.txt --content "hello"
///   shepaw os file.list --path /tmp --detail true
///   shepaw os app.open --app_name Safari
///   shepaw os app.url --url https://dart.dev
///   shepaw os clipboard.read
///   shepaw os clipboard.write --text "copied text"
///   shepaw os process.list --sort_by cpu --limit 10
///   shepaw os process.kill --pid 1234
///   shepaw os macos.applescript --script 'display dialog "Hello"'
///   shepaw os system_info --category overview
///   shepaw os screenshot
///
/// 所有命令执行委托给 os_tool_executor.runTool()，复用现有的风险分类和配置注入。
class OsCliNamespace extends CliNamespace {
  static final instance = OsCliNamespace._();
  OsCliNamespace._();

  @override
  String get namespace => 'os';

  @override
  String get description =>
      'Local OS tools — shell, file, app, clipboard, process, system';

  /// 按 category 分组的 sub-namespaces
  @override
  Map<String, CliNamespace> get subNamespaces {
    final registry = OsToolRegistry.instance;
    final platform = _currentPlatform;

    // 过滤当前平台支持的非 network 工具
    final osTools = registry.tools
        .where((t) =>
            t.category != 'network' &&
            t.supportedPlatforms.contains(platform))
        .toList();

    // 按 category 分组
    final grouped = <String, List<OsToolDefinition>>{};
    for (final tool in osTools) {
      grouped.putIfAbsent(tool.category, () => []).add(tool);
    }

    return {
      for (final entry in grouped.entries)
        entry.key: _OsCategorySubNamespace(entry.key, entry.value),
    };
  }

  /// 扁平命令：跨分类的快捷命令
  @override
  Map<String, CliCommand> get commands => {
        'list': _OsListAllCommand(),
      };

  @override
  Map<String, dynamic> getHelp() {
    final registry = OsToolRegistry.instance;
    final platform = OsCliNamespace._currentPlatform;
    final osTools = registry.tools
        .where((t) =>
            t.category != 'network' &&
            t.supportedPlatforms.contains(platform))
        .toList();

    // 按 category 分组生成 subcommand 文档
    final grouped = <String, List<OsToolDefinition>>{};
    for (final tool in osTools) {
      grouped.putIfAbsent(tool.category, () => []).add(tool);
    }

    final subcommands = <String, String>{
      'list': 'List all OS tools on the current platform',
    };
    for (final entry in grouped.entries) {
      for (final tool in entry.value) {
        final shortName = _toolShortName(tool.name, entry.key);
        subcommands['${entry.key}.$shortName'] = tool.description;
      }
    }

    final examples = <String>[
      'shepaw os list',
      'shepaw os command.shell --command "ls -la"',
      'shepaw os command.sysinfo --category overview',
      'shepaw os file.read --path /tmp/test.txt',
      'shepaw os file.write --path /tmp/test.txt --content "hello world"',
      'shepaw os file.list --path /tmp --detail true',
      'shepaw os file.delete --path /tmp/test.txt',
      'shepaw os file.move --source /tmp/a.txt --destination /tmp/b.txt',
      'shepaw os app.open --app_name Safari',
      'shepaw os app.url --url https://dart.dev',
      'shepaw os clipboard.read',
      'shepaw os clipboard.write --text "copied text"',
      'shepaw os process.list --sort_by cpu --limit 10',
      'shepaw os process.detail --pid 1234',
      'shepaw os process.kill --pid 1234',
      'shepaw os process.connections --pid 1234',
    ];

    if (Platform.isMacOS) {
      examples.addAll([
        'shepaw os command.screenshot',
        'shepaw os macos.applescript --script \'display dialog "Hello"\'',
      ]);
    }

    return {
      'namespace': namespace,
      'description': description,
      'subcommands': subcommands,
      'examples': examples,
    };
  }

  static String get _currentPlatform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }
}

// ── 工具名简化映射 ──────────────────────────────────────────────────────────

/// 将完整工具名转换为 sub-namespace 内的短名
///
/// 规则：去掉 category 前缀（如 file_read → read, process_list → list）
/// 特殊映射用于不规则命名
String _toolShortName(String toolName, String category) {
  const specialMapping = {
    'shell_exec': 'shell',
    'system_info': 'sysinfo',
    'applescript_exec': 'applescript',
    'app_open': 'open',
    'url_open': 'url',
    'clipboard_read': 'read',
    'clipboard_write': 'write',
    'file_read': 'read',
    'file_write': 'write',
    'file_delete': 'delete',
    'file_move': 'move',
    'file_list': 'list',
    'process_list': 'list',
    'process_kill': 'kill',
    'process_detail': 'detail',
    'network_connections': 'connections',
    'screenshot': 'screenshot',
  };

  return specialMapping[toolName] ?? toolName.replaceFirst('${category}_', '');
}

// ── Category Sub-Namespace ───────────────────────────────────────────────────

class _OsCategorySubNamespace extends CliNamespace {
  final String _category;
  final List<OsToolDefinition> _tools;

  _OsCategorySubNamespace(this._category, this._tools);

  @override
  String get namespace => _category;

  @override
  String get description => 'OS tools — $_category';

  @override
  Map<String, CliCommand> get commands => {
        for (final tool in _tools)
          _toolShortName(tool.name, _category):
              OsToolCliCommand(tool, _toolShortName(tool.name, _category)),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': 'os.$_category',
        'description': description,
        'subcommands': {
          for (final tool in _tools)
            _toolShortName(tool.name, _category): tool.description,
        },
      };
}

// ── 通用 OS 工具 CLI 命令 ─────────────────────────────────────────────────────

/// 通用 CLI 命令包装器，将 [OsToolDefinition] 适配为 [CliCommand]。
///
/// 从 flags 提取参数，委托给 `os_tool_executor.runTool()` 执行。
/// 帮助文档自动从工具的 `parameterSchema` 生成。
class OsToolCliCommand extends CliCommand {
  final OsToolDefinition toolDef;
  final String _shortName;

  OsToolCliCommand(this.toolDef, this._shortName);

  @override
  String get name => _shortName;

  @override
  String get description => toolDef.description;

  @override
  Map<String, dynamic> getHelp() {
    final props =
        toolDef.parameterSchema['properties'] as Map<String, dynamic>? ?? {};
    final required = (toolDef.parameterSchema['required'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toSet() ??
        {};

    final flagDocs = <String, Map<String, dynamic>>{};
    for (final entry in props.entries) {
      final prop = entry.value as Map<String, dynamic>;
      flagDocs[entry.key] = {
        'description': prop['description'] ?? '',
        'type': prop['type'] ?? 'string',
        'required': required.contains(entry.key),
        if (prop.containsKey('enum')) 'enum': prop['enum'],
        if (prop.containsKey('default')) 'default': prop['default'],
      };
    }

    return {
      'command': _shortName,
      'tool_name': toolDef.name,
      'description': description,
      'risk_level': toolDef.defaultRiskLevel,
      'flags': flagDocs,
      'usage':
          'shepaw os ${toolDef.category}.$_shortName${_usageString(props, required)}',
    };
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    // 将 string flags 转换为适当类型的 args（根据 parameterSchema）
    final args = _convertFlags(flags);
    return await os_exec.runTool(toolDef.name, args);
  }

  /// 将 CLI string flags 根据 parameterSchema 转换为正确类型
  Map<String, dynamic> _convertFlags(Map<String, String> flags) {
    final props =
        toolDef.parameterSchema['properties'] as Map<String, dynamic>? ?? {};
    final result = <String, dynamic>{};

    for (final entry in flags.entries) {
      final propSchema = props[entry.key] as Map<String, dynamic>?;
      if (propSchema == null) {
        // 未知参数，保留原始字符串
        result[entry.key] = entry.value;
        continue;
      }

      final type = propSchema['type'] as String? ?? 'string';
      switch (type) {
        case 'integer':
          result[entry.key] = int.tryParse(entry.value) ?? entry.value;
          break;
        case 'number':
          result[entry.key] = num.tryParse(entry.value) ?? entry.value;
          break;
        case 'boolean':
          result[entry.key] =
              entry.value == 'true' || entry.value == '1';
          break;
        default:
          result[entry.key] = entry.value;
      }
    }

    return result;
  }

  String _usageString(
      Map<String, dynamic> props, Set<String> required) {
    if (props.isEmpty) return '';
    final parts = <String>[];
    for (final key in props.keys) {
      if (required.contains(key)) {
        parts.add('--$key <$key>');
      } else {
        parts.add('[--$key <$key>]');
      }
    }
    return ' ${parts.join(" ")}';
  }
}

// ── List all OS tools ────────────────────────────────────────────────────────

class _OsListAllCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all OS tools on the current platform';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'usage': 'shepaw os list',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = OsToolRegistry.instance;
    final platform = OsCliNamespace._currentPlatform;
    final tools = registry.tools
        .where((t) =>
            t.category != 'network' &&
            t.supportedPlatforms.contains(platform))
        .toList();

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final t in tools) {
      grouped.putIfAbsent(t.category, () => []).add({
        'name': t.name,
        'short_name': _toolShortName(t.name, t.category),
        'description': t.description,
        'risk': t.defaultRiskLevel,
        'usage': 'shepaw os ${t.category}.${_toolShortName(t.name, t.category)}',
      });
    }

    return {
      'platform': platform,
      'tools_by_category': grouped,
      'total_count': tools.length,
    };
  }
}

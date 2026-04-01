import '../../cli_base.dart';
import '../../../models/cli_tool_definition.dart';
import '../../../services/cli_tool_registry.dart';
import '../../../clis/shepaw/shepaw_cli.dart';

/// [META 层] cli-tools 子命名空间 — 管理外部 CLI 工具
///
/// 提供安装、卸载、列表查看和重新扫描外部 CLI 工具的能力。
/// 外部工具安装目录: ~/shepaw/cli-tools/
///
/// Actions:
///   list      — 列出所有已安装的外部 CLI 工具
///   install   — 安装工具（--file ZIP 文件路径 或 --url 下载地址）
///   uninstall — 卸载工具（--namespace 工具命名空间名）
///   rescan    — 重新扫描 cli-tools 目录
///
/// 示例:
/// ```
/// shepaw meta cli-tools.list
/// shepaw meta cli-tools.install --file /path/to/tool.zip
/// shepaw meta cli-tools.install --url https://example.com/tool.zip
/// shepaw meta cli-tools.uninstall --namespace weather
/// shepaw meta cli-tools.rescan
/// ```
class CliToolsSubNamespace extends CliNamespace {
  static final instance = CliToolsSubNamespace._();
  CliToolsSubNamespace._();

  @override
  String get namespace => 'cli-tools';

  @override
  String get description => 'Manage external CLI tools (install, uninstall, list)';

  @override
  Map<String, CliCommand> get commands => {
        'list': _CliToolsListCommand(),
        'install': _CliToolsInstallCommand(),
        'uninstall': _CliToolsUninstallCommand(),
        'rescan': _CliToolsRescanCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': 'meta.$namespace',
        'description': description,
        'directory': CliToolRegistry.instance.directoryPath,
        'subcommands': {
          'list': 'List all installed external CLI tools',
          'install':
              'Install a tool from ZIP (--file <path>) or URL (--url <url>)',
          'uninstall': 'Uninstall a tool by namespace (--namespace <name>)',
          'rescan': 'Re-scan cli-tools directory for changes',
        },
        'examples': [
          'shepaw meta cli-tools.list',
          'shepaw meta cli-tools.install --file /path/to/tool.zip',
          'shepaw meta cli-tools.install --url https://example.com/tool.zip',
          'shepaw meta cli-tools.uninstall --namespace weather',
          'shepaw meta cli-tools.rescan',
        ],
      };
}

// ── List installed tools ─────────────────────────────────────────────────────

class _CliToolsListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all installed external CLI tools';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'usage': 'shepaw meta cli-tools.list',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final registry = CliToolRegistry.instance;
    final tools = registry.tools;

    if (tools.isEmpty) {
      return {
        'installed_tools': [],
        'total': 0,
        'directory': registry.directoryPath,
        'hint':
            'No external CLI tools installed. '
            'Place tool folders in ${registry.directoryPath} or use '
            '"shepaw meta cli-tools.install --file <path>"',
      };
    }

    return {
      'installed_tools': tools
          .map((t) => {
                'namespace': t.namespace,
                'displayName': t.displayName,
                'description': t.description,
                'version': t.version,
                'handler_type': t.handlerType,
                'commands': t.commands.keys.toList(),
                'platforms': t.supportedPlatforms.toList(),
              })
          .toList(),
      'total': tools.length,
      'directory': registry.directoryPath,
    };
  }
}

// ── Install tool ─────────────────────────────────────────────────────────────

class _CliToolsInstallCommand extends CliCommand {
  @override
  String get name => 'install';

  @override
  String get description => 'Install an external CLI tool from ZIP file or URL';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'file': 'Path to a local ZIP file containing the CLI tool',
          'url': 'URL to download a ZIP file from',
          'overwrite':
              'Set to "true" to overwrite an existing tool with the same namespace',
        },
        'usage': 'shepaw meta cli-tools.install --file <path> [--overwrite true]',
        'examples': [
          'shepaw meta cli-tools.install --file /path/to/tool.zip',
          'shepaw meta cli-tools.install --url https://example.com/tool.zip',
          'shepaw meta cli-tools.install --file /path/to/tool.zip --overwrite true',
        ],
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final filePath = flags['file'];
    final url = flags['url'];
    final overwrite = flags['overwrite'] == 'true';

    if (filePath == null && url == null) {
      return {
        'error': 'Missing --file or --url flag',
        'usage':
            'shepaw meta cli-tools.install --file <path> or --url <url>',
      };
    }

    try {
      final registry = CliToolRegistry.instance;
      final CliToolDefinition result;

      if (filePath != null) {
        result = await registry.installFromZip(filePath, overwrite: overwrite);
      } else {
        result = await registry.installFromUrl(url!, overwrite: overwrite);
      }

      // Reload namespaces in ShepawCLI
      ShepawCLI.instance.reloadExternalTools();

      return {
        'success': true,
        'action': 'install',
        'tool': {
          'namespace': result.namespace,
          'displayName': result.displayName,
          'version': result.version,
          'commands': result.commands.keys.toList(),
        },
        'message':
            'Tool "${result.displayName}" installed successfully. '
            'Use "shepaw ${result.namespace} <command>" to invoke.',
      };
    } on CliToolConflictException catch (e) {
      return {
        'error':
            'Namespace "${e.namespace}" already exists. '
            'Use --overwrite true to replace.',
        'existing_namespace': e.namespace,
      };
    } catch (e) {
      return {'error': 'Install failed: $e'};
    }
  }
}

// ── Uninstall tool ───────────────────────────────────────────────────────────

class _CliToolsUninstallCommand extends CliCommand {
  @override
  String get name => 'uninstall';

  @override
  String get description => 'Uninstall an external CLI tool';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'namespace': 'The namespace of the tool to uninstall (required)',
        },
        'usage': 'shepaw meta cli-tools.uninstall --namespace <name>',
        'examples': [
          'shepaw meta cli-tools.uninstall --namespace weather',
        ],
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final namespace = flags['namespace'];
    if (namespace == null || namespace.isEmpty) {
      return {
        'error': 'Missing --namespace flag',
        'usage': 'shepaw meta cli-tools.uninstall --namespace <name>',
        'installed': CliToolRegistry.instance.allNamespaces.toList(),
      };
    }

    try {
      await CliToolRegistry.instance.uninstall(namespace);

      // Reload namespaces in ShepawCLI
      ShepawCLI.instance.reloadExternalTools();

      return {
        'success': true,
        'action': 'uninstall',
        'namespace': namespace,
        'message': 'Tool "$namespace" uninstalled successfully.',
      };
    } catch (e) {
      return {'error': 'Uninstall failed: $e'};
    }
  }
}

// ── Rescan directory ─────────────────────────────────────────────────────────

class _CliToolsRescanCommand extends CliCommand {
  @override
  String get name => 'rescan';

  @override
  String get description => 'Re-scan the cli-tools directory for changes';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'usage': 'shepaw meta cli-tools.rescan',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    await CliToolRegistry.instance.rescan();

    // Reload namespaces in ShepawCLI
    ShepawCLI.instance.reloadExternalTools();

    final tools = CliToolRegistry.instance.tools;

    return {
      'success': true,
      'action': 'rescan',
      'directory': CliToolRegistry.instance.directoryPath,
      'tools_found': tools.length,
      'namespaces': tools.map((t) => t.namespace).toList(),
    };
  }
}

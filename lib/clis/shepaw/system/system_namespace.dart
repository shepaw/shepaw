import '../../cli_base.dart';
import 'info_command.dart';
import 'tools_list_command.dart';
import 'tools_detail_command.dart';
import 'capabilities_command.dart';

/// System namespace — query system information, tool inventory, and capabilities.
///
/// Subcommands:
/// - `info` — Basic app information (version, platform, time)
/// - `tools-list` — List all available tools
/// - `tools-detail --name <tool-name>` — Full documentation for a specific tool
/// - `capabilities` — Summary of system capabilities
class SystemNamespace extends CliNamespace {
  static final instance = SystemNamespace._();
  SystemNamespace._();

  @override
  String get namespace => 'system';

  @override
  String get description => 'Query system information and tool inventory';

  @override
  Map<String, CliCommand> get commands => {
        'info': InfoCommand(),
        'tools-list': ToolsListCommand(),
        'tools-detail': ToolsDetailCommand(),
        'capabilities': CapabilitiesCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': 'system',
        'description': description,
        'subcommands': {
          'info': 'Display basic system information',
          'tools-list': 'List all available tools and categories',
          'tools-detail': 'Get full docs for any tool (requires --name flag)',
          'capabilities': 'Summary of system capabilities',
        },
        'examples': [
          'shepaw system info',
          'shepaw system tools-list',
          'shepaw system tools-detail --name file_read',
          'shepaw system capabilities',
        ],
      };
}

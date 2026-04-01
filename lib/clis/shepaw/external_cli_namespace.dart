import '../cli_base.dart';
import '../../models/cli_tool_definition.dart';
import '../../services/cli_tool_registry.dart';

/// Dynamic [CliNamespace] implementation backed by an external CLI tool.
///
/// Each installed external tool (`~/shepaw/cli-tools/<namespace>/`) becomes an
/// [ExternalCliNamespace] that routes commands to the tool's handler process.
///
/// Example:
/// ```
/// shepaw weather today --city Beijing
/// ```
/// Routes to the `weather` tool, calling its `today` command.
class ExternalCliNamespace extends CliNamespace {
  final CliToolDefinition tool;

  ExternalCliNamespace(this.tool);

  @override
  String get namespace => tool.namespace;

  @override
  String get description => tool.description;

  @override
  Map<String, CliCommand> get commands => {
        for (final entry in tool.commands.entries)
          entry.key: ExternalCliCommand(tool, entry.value),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'type': 'external',
        'description': '${tool.displayName} v${tool.version} (external CLI tool)',
        'subcommands': {
          for (final cmd in tool.commands.entries)
            cmd.key: cmd.value.description,
        },
        'examples': [
          for (final cmd in tool.commands.entries)
            'shepaw ${tool.namespace} ${cmd.key}${_exampleFlags(cmd.value)}',
        ],
      };

  /// Generate example flag string from parameter schema.
  String _exampleFlags(CliToolCommandDef cmd) {
    final props =
        cmd.parameterSchema['properties'] as Map<String, dynamic>? ?? {};
    if (props.isEmpty) return '';

    final required =
        (cmd.parameterSchema['required'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toSet() ??
        {};

    final parts = <String>[];
    for (final entry in props.entries) {
      if (required.contains(entry.key)) {
        parts.add('--${entry.key} <${entry.key}>');
      }
    }

    return parts.isEmpty ? '' : ' ${parts.join(" ")}';
  }
}

/// A single command within an [ExternalCliNamespace].
///
/// Delegates execution to [CliToolRegistry.executeCommand], which spawns
/// the tool's handler process and communicates via stdin/stdout JSON.
class ExternalCliCommand extends CliCommand {
  final CliToolDefinition tool;
  final CliToolCommandDef commandDef;

  ExternalCliCommand(this.tool, this.commandDef);

  @override
  String get name => commandDef.name;

  @override
  String get description => commandDef.description;

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'namespace': tool.namespace,
        'type': 'external',
        'parameters': commandDef.parameterSchema,
        'usage':
            'shepaw ${tool.namespace} $name${_usageFlags()}',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) {
    return CliToolRegistry.instance.executeCommand(
      tool.namespace,
      commandDef.name,
      flags,
    );
  }

  String _usageFlags() {
    final props =
        commandDef.parameterSchema['properties'] as Map<String, dynamic>? ?? {};
    if (props.isEmpty) return '';

    return ' ${props.keys.map((k) => '[--$k <value>]').join(" ")}';
  }
}

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
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['type'] = 'external';
    base['version'] = tool.version;
    return base;
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
  String get usage => 'shepaw ${tool.namespace} $name${_usageFlags()}';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['namespace'] = tool.namespace;
    base['type'] = 'external';
    base['parameters'] = commandDef.parameterSchema;
    return base;
  }

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

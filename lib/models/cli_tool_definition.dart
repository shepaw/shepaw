/// Data models for external CLI tool definitions.
///
/// External CLI tools are installed under `~/shepaw/cli-tools/` and discovered
/// at runtime via their `cli-tool.json` manifest files.
///
/// Each tool provides a namespace with one or more commands. Commands are
/// executed by spawning the tool's handler process and communicating via
/// stdin/stdout JSON.
library;

/// Describes a single command within an external CLI tool.
class CliToolCommandDef {
  /// Command name (e.g. "today", "forecast").
  final String name;

  /// Human-readable description for help text and LLM prompts.
  final String description;

  /// JSON Schema for command parameters.
  ///
  /// This schema is used both for LLM tool generation and for validating
  /// flags before execution.
  final Map<String, dynamic> parameterSchema;

  const CliToolCommandDef({
    required this.name,
    required this.description,
    required this.parameterSchema,
  });

  factory CliToolCommandDef.fromJson(String name, Map<String, dynamic> json) {
    return CliToolCommandDef(
      name: name,
      description: json['description'] as String? ?? '',
      parameterSchema:
          (json['parameters'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Map<String, dynamic> toJson() => {
        'description': description,
        'parameters': parameterSchema,
      };
}

/// Describes an external CLI tool parsed from a `cli-tool.json` manifest.
class CliToolDefinition {
  /// Namespace name used in CLI routing (e.g. "weather").
  ///
  /// Must not conflict with built-in namespaces (context, chat, tools, etc.).
  final String namespace;

  /// Human-readable display name (e.g. "Weather Tool").
  final String displayName;

  /// Brief description shown in help text and LLM tool descriptions.
  final String description;

  /// Semantic version string (e.g. "1.0.0").
  final String version;

  /// Absolute path to the handler executable or script.
  final String handlerPath;

  /// Handler type: `'script'` (executed via shell) or `'binary'` (direct exec).
  final String handlerType;

  /// Absolute path to the tool's installation directory.
  final String directoryPath;

  /// Platforms this tool supports: 'macos', 'linux', 'windows', 'android', 'ios'.
  final Set<String> supportedPlatforms;

  /// All commands provided by this tool.
  final Map<String, CliToolCommandDef> commands;

  const CliToolDefinition({
    required this.namespace,
    required this.displayName,
    required this.description,
    required this.version,
    required this.handlerPath,
    required this.handlerType,
    required this.directoryPath,
    required this.supportedPlatforms,
    required this.commands,
  });

  /// Parse a [CliToolDefinition] from the JSON contents of `cli-tool.json`.
  ///
  /// [json] is the decoded manifest content.
  /// [dirPath] is the absolute path to the tool's directory.
  factory CliToolDefinition.fromJson(
    Map<String, dynamic> json,
    String dirPath,
  ) {
    final namespace = json['namespace'] as String;
    final handler = json['handler'] as Map<String, dynamic>;
    final handlerType = handler['type'] as String? ?? 'script';
    final handlerRelPath = handler['path'] as String;
    final handlerPath = '$dirPath/$handlerRelPath';

    final platformsList = json['supportedPlatforms'] as List<dynamic>?;
    final platforms = platformsList != null
        ? platformsList.map((e) => e.toString()).toSet()
        : const <String>{'macos', 'linux', 'windows'};

    final commandsJson =
        json['commands'] as Map<String, dynamic>? ?? const {};
    final commands = <String, CliToolCommandDef>{};
    for (final entry in commandsJson.entries) {
      commands[entry.key] = CliToolCommandDef.fromJson(
        entry.key,
        entry.value as Map<String, dynamic>,
      );
    }

    return CliToolDefinition(
      namespace: namespace,
      displayName: json['displayName'] as String? ?? namespace,
      description: json['description'] as String? ?? '',
      version: json['version'] as String? ?? '0.0.0',
      handlerPath: handlerPath,
      handlerType: handlerType,
      directoryPath: dirPath,
      supportedPlatforms: platforms,
      commands: commands,
    );
  }

  /// Serialize back to JSON (for debugging / export).
  Map<String, dynamic> toJson() => {
        'namespace': namespace,
        'displayName': displayName,
        'description': description,
        'version': version,
        'handler': {
          'type': handlerType,
          'path': handlerPath,
        },
        'supportedPlatforms': supportedPlatforms.toList(),
        'commands': {
          for (final entry in commands.entries)
            entry.key: entry.value.toJson(),
        },
      };
}

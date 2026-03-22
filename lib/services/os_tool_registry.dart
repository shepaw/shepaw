/// OS Tool Registry — definitions, platform filtering, and LLM schema export.
///
/// Mirrors the pattern of [UIComponentRegistry] but for local OS operations
/// (shell commands, file I/O, clipboard, screenshots, etc.).
library;

import 'dart:io' show Platform;

/// Describes a single OS tool that can be invoked by a local LLM agent.
class OsToolDefinition {
  /// Tool name used in function-calling (e.g. `shell_exec`).
  final String name;

  /// Human-readable description shown to the LLM and in config UI.
  final String description;

  /// JSON Schema for parameters (OpenAI `parameters` / Claude `input_schema`).
  final Map<String, dynamic> parameterSchema;

  /// Default risk level when no argument-based classification is available.
  final String defaultRiskLevel; // 'safe', 'lowRisk', 'highRisk'

  /// Platforms this tool supports: 'macos', 'linux', 'windows', 'android', 'ios'.
  final Set<String> supportedPlatforms;

  /// UI grouping category.
  final String category;

  const OsToolDefinition({
    required this.name,
    required this.description,
    required this.parameterSchema,
    required this.defaultRiskLevel,
    required this.supportedPlatforms,
    required this.category,
  });
}

/// Central registry for all OS tool definitions.
class OsToolRegistry {
  OsToolRegistry._();
  static final OsToolRegistry instance = OsToolRegistry._();

  // ---------------------------------------------------------------------------
  // Tool definitions
  // ---------------------------------------------------------------------------

  static const _desktop = {'macos', 'linux', 'windows'};
  static const _desktopAndroid = {'macos', 'linux', 'windows', 'android'};
  static const _all = {'macos', 'linux', 'windows', 'android', 'ios'};

  final List<OsToolDefinition> tools = const [
    // --- Command & System ---
    OsToolDefinition(
      name: 'shell_exec',
      description:
          'Execute a shell command on the local machine. '
          'Use for running terminal commands, scripts, and system utilities.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'command': {
            'type': 'string',
            'description': 'The shell command to execute',
          },
          'timeout': {
            'type': 'integer',
            'description': 'Timeout in seconds (default: 30, max: 300)',
          },
          'working_dir': {
            'type': 'string',
            'description':
                "Working directory for the command (default: user's home)",
          },
        },
        'required': ['command'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _desktop,
      category: 'command',
    ),
    OsToolDefinition(
      name: 'system_info',
      description: 'Get system information (OS, CPU, memory, disk, etc.).',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'category': {
            'type': 'string',
            'enum': [
              'overview',
              'cpu',
              'memory',
              'disk',
              'network',
              'battery',
              'displays',
            ],
            'description':
                "Category of system info to retrieve (default: 'overview')",
          },
        },
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _all,
      category: 'command',
    ),

    // --- File Operations ---
    OsToolDefinition(
      name: 'file_read',
      description: 'Read the contents of a file.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the file to read',
          },
          'max_bytes': {
            'type': 'integer',
            'description': 'Maximum bytes to read (default: 10240)',
          },
        },
        'required': ['path'],
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _desktopAndroid,
      category: 'file',
    ),
    OsToolDefinition(
      name: 'file_write',
      description:
          'Write content to a file. Creates the file if it does not exist.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the file to write',
          },
          'content': {
            'type': 'string',
            'description': 'Content to write to the file',
          },
          'append': {
            'type': 'boolean',
            'description':
                'If true, append to existing file instead of overwriting (default: false)',
          },
        },
        'required': ['path', 'content'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _desktopAndroid,
      category: 'file',
    ),
    OsToolDefinition(
      name: 'file_delete',
      description: 'Delete a file or directory.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description':
                'Absolute path to the file or directory to delete',
          },
          'recursive': {
            'type': 'boolean',
            'description':
                'If true, delete directories recursively (default: false)',
          },
        },
        'required': ['path'],
      },
      defaultRiskLevel: 'highRisk',
      supportedPlatforms: _desktopAndroid,
      category: 'file',
    ),
    OsToolDefinition(
      name: 'file_move',
      description: 'Move or rename a file or directory.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'source': {
            'type': 'string',
            'description': 'Absolute path of the source file or directory',
          },
          'destination': {
            'type': 'string',
            'description': 'Absolute path of the destination',
          },
        },
        'required': ['source', 'destination'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _desktopAndroid,
      category: 'file',
    ),
    OsToolDefinition(
      name: 'file_list',
      description: 'List the contents of a directory.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': 'Absolute path to the directory to list',
          },
          'show_hidden': {
            'type': 'boolean',
            'description': 'Include hidden files (default: false)',
          },
          'detail': {
            'type': 'boolean',
            'description':
                'Show detailed info (size, modified time) (default: false)',
          },
        },
        'required': ['path'],
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _all,
      category: 'file',
    ),

    // --- App & Browser ---
    OsToolDefinition(
      name: 'app_open',
      description: 'Open an application by name.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'app_name': {
            'type': 'string',
            'description':
                "Name of the application to open (e.g., 'Safari', 'Terminal')",
          },
        },
        'required': ['app_name'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _desktop,
      category: 'app',
    ),
    OsToolDefinition(
      name: 'url_open',
      description: "Open a URL in the default browser.",
      parameterSchema: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The URL to open',
          },
        },
        'required': ['url'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _all,
      category: 'app',
    ),

    // --- Screenshot ---
    OsToolDefinition(
      name: 'screenshot',
      description: 'Take a screenshot of the screen.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'region': {
            'type': 'string',
            'description':
                "Screen region: 'full' (default), 'window', or 'x,y,w,h' for custom rectangle",
          },
          'save_path': {
            'type': 'string',
            'description':
                'Path to save the screenshot (default: temp file)',
          },
        },
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _desktop,
      category: 'command',
    ),

    // --- Clipboard ---
    OsToolDefinition(
      name: 'clipboard_read',
      description: 'Read the current contents of the clipboard.',
      parameterSchema: {
        'type': 'object',
        'properties': {},
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _all,
      category: 'clipboard',
    ),
    OsToolDefinition(
      name: 'clipboard_write',
      description: 'Write text to the clipboard.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'text': {
            'type': 'string',
            'description': 'Text to copy to the clipboard',
          },
        },
        'required': ['text'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: _all,
      category: 'clipboard',
    ),

    // --- macOS Only ---
    OsToolDefinition(
      name: 'applescript_exec',
      description:
          'Execute an AppleScript. Useful for automating macOS applications and system features.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'script': {
            'type': 'string',
            'description': 'The AppleScript code to execute',
          },
        },
        'required': ['script'],
      },
      defaultRiskLevel: 'lowRisk',
      supportedPlatforms: {'macos'},
      category: 'macos',
    ),

    // --- Process Management ---
    OsToolDefinition(
      name: 'process_list',
      description:
          'List running processes on the local machine. '
          'Supports filtering by name, sorting by cpu/memory/pid, and limiting results.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'filter': {
            'type': 'string',
            'description':
                'Filter processes by name (case-insensitive substring match)',
          },
          'sort_by': {
            'type': 'string',
            'enum': ['cpu', 'memory', 'pid', 'name'],
            'description': "Sort order (default: 'cpu')",
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum number of processes to return (default: 50)',
          },
        },
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _desktop,
      category: 'process',
    ),
    OsToolDefinition(
      name: 'process_kill',
      description:
          'Kill a process by PID. Sends SIGTERM by default, or SIGKILL with force=true. '
          'Protected system processes cannot be killed.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'pid': {
            'type': 'integer',
            'description': 'The process ID to kill',
          },
          'force': {
            'type': 'boolean',
            'description':
                'If true, send SIGKILL instead of SIGTERM (default: false)',
          },
        },
        'required': ['pid'],
      },
      defaultRiskLevel: 'highRisk',
      supportedPlatforms: _desktop,
      category: 'process',
    ),
    OsToolDefinition(
      name: 'process_detail',
      description:
          'Get detailed information about a specific process by PID, '
          'including CPU, memory, command line, and open files.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'pid': {
            'type': 'integer',
            'description': 'The process ID to inspect',
          },
        },
        'required': ['pid'],
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _desktop,
      category: 'process',
    ),
    OsToolDefinition(
      name: 'network_connections',
      description:
          'List active network connections (TCP/UDP). '
          'Optionally filter by a specific process PID.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'pid': {
            'type': 'integer',
            'description': 'Filter connections by process ID (optional)',
          },
        },
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _desktop,
      category: 'process',
    ),
  ];

  // ---------------------------------------------------------------------------
  // Platform helpers
  // ---------------------------------------------------------------------------

  /// Returns the current platform identifier.
  String get currentPlatform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  /// All tool names.
  Set<String> get allToolNames => tools.map((t) => t.name).toSet();

  /// Tool names supported on the current platform.
  Set<String> get platformToolNames =>
      tools
          .where((t) => t.supportedPlatforms.contains(currentPlatform))
          .map((t) => t.name)
          .toSet();

  /// Whether [toolName] is a known OS tool.
  bool isOsTool(String toolName) =>
      tools.any((t) => t.name == toolName);

  /// Lookup a definition by name, or null.
  OsToolDefinition? getDefinition(String toolName) {
    for (final t in tools) {
      if (t.name == toolName) return t;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // LLM tool formats (filtered by platform + enabled set)
  // ---------------------------------------------------------------------------

  /// Returns OS tools in OpenAI function-calling format, filtered by
  /// current platform and the user-enabled set.
  List<Map<String, dynamic>> openAITools({Set<String>? enabledTools}) {
    return _filteredTools(enabledTools)
        .map((t) => <String, dynamic>{
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameterSchema,
              },
            })
        .toList();
  }

  /// Returns OS tools in Claude (Anthropic) format.
  List<Map<String, dynamic>> claudeTools({Set<String>? enabledTools}) {
    return _filteredTools(enabledTools)
        .map((t) => <String, dynamic>{
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameterSchema,
            })
        .toList();
  }

  /// System prompt suffix describing available OS tools.
  String systemPromptSuffix(Set<String> enabledTools) {
    final filtered = _filteredTools(enabledTools);
    if (filtered.isEmpty) return '';
    final toolLines = filtered
        .map((t) => '- ${t.name}: ${t.description.split('.').first.trim().toLowerCase()}')
        .join('\n');
    return '''

You also have access to OS-level tools that let you operate the local machine.
Use them when the user asks you to interact with files, run commands, take screenshots, etc.
Available OS tools:
$toolLines
IMPORTANT: These tools execute real actions on the user's device. Always confirm destructive operations.
For file/command operations, prefer using these tools over describing steps in text.''';
  }

  // ---------------------------------------------------------------------------
  // Grouping for UI
  // ---------------------------------------------------------------------------

  /// Category labels (localized externally, these are keys).
  static const Map<String, String> categoryLabels = {
    'command': 'Command & System',
    'file': 'File Operations',
    'app': 'App & Browser',
    'clipboard': 'Clipboard',
    'macos': 'macOS Only',
    'process': 'Process Management',
  };

  /// Returns tools grouped by category, preserving definition order.
  Map<String, List<OsToolDefinition>> get toolsByCategory {
    final map = <String, List<OsToolDefinition>>{};
    for (final t in tools) {
      map.putIfAbsent(t.category, () => []).add(t);
    }
    return map;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Iterable<OsToolDefinition> _filteredTools(Set<String>? enabledTools) {
    final platform = currentPlatform;
    return tools.where((t) {
      if (!t.supportedPlatforms.contains(platform)) return false;
      if (enabledTools != null && !enabledTools.contains(t.name)) return false;
      return true;
    });
  }
}

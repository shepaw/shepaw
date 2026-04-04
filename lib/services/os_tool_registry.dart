/// OS Tool Registry — definitions, platform filtering, and LLM schema export.
///
/// Mirrors the pattern of [UIComponentRegistry] but for local OS operations
/// (shell commands, file I/O, clipboard, screenshots, etc.).
///
/// 工具名称规范：
///   - [name]    内部名 / 执行器分派键（如 `shell_exec`）
///   - [cliPath] CLI 分层路径，对 LLM 可见（如 `os.shell.exec`）
///   LLM function-calling 使用 cliPath；runTool() 使用 name。
library;

import 'dart:io' show Platform;

import '../models/cli_config_field.dart';

/// Describes a single OS tool that can be invoked by a local LLM agent.
class OsToolDefinition {
  /// Internal tool name used by [runTool] dispatch (e.g. `shell_exec`).
  final String name;

  /// Hierarchical CLI path exposed to the LLM (e.g. `os.shell.exec`).
  ///
  /// Format: `<namespace>.<sub-namespace>.<action>`
  /// Maps to CLI: `shepaw tools <cliPath>`
  final String cliPath;

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

  /// User-configurable fields for this tool.
  ///
  /// Empty list means the tool needs no user configuration (only enabled/sheExclusive toggles).
  /// Non-empty list triggers a "Configure" entry in the CLI config UI, where each field
  /// is rendered as an appropriate form widget based on its [CliConfigFieldType].
  final List<CliConfigField> configSpec;

  /// Whether this tool is restricted to She only by default.
  ///
  /// The user can override this per-tool in the config UI (persisted to [ToolConfig.sheExclusive]).
  final bool sheExclusive;

  const OsToolDefinition({
    required this.name,
    required this.cliPath,
    required this.description,
    required this.parameterSchema,
    required this.defaultRiskLevel,
    required this.supportedPlatforms,
    required this.category,
    this.configSpec = const [],
    this.sheExclusive = false,
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
    // ── Shell (command & system) ─────────────────────────────────────────────
    OsToolDefinition(
      name: 'shell_exec',
      cliPath: 'os.shell.exec',
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
      cliPath: 'os.shell.info',
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

    // ── File ─────────────────────────────────────────────────────────────────
    OsToolDefinition(
      name: 'file_read',
      cliPath: 'os.file.read',
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
      cliPath: 'os.file.write',
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
      cliPath: 'os.file.delete',
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
      cliPath: 'os.file.move',
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
      cliPath: 'os.file.list',
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

    // ── App & Browser ────────────────────────────────────────────────────────
    OsToolDefinition(
      name: 'app_open',
      cliPath: 'os.app.open',
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
      cliPath: 'os.app.url',
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

    // ── Screenshot (grouped under app) ───────────────────────────────────────
    OsToolDefinition(
      name: 'screenshot',
      cliPath: 'os.app.screenshot',
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
      category: 'app',
    ),

    // ── Clipboard ────────────────────────────────────────────────────────────
    OsToolDefinition(
      name: 'clipboard_read',
      cliPath: 'os.clipboard.read',
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
      cliPath: 'os.clipboard.write',
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

    // ── macOS Only ───────────────────────────────────────────────────────────
    OsToolDefinition(
      name: 'applescript_exec',
      cliPath: 'os.applescript.exec',
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

    // ── Process Management ───────────────────────────────────────────────────
    OsToolDefinition(
      name: 'process_list',
      cliPath: 'os.process.list',
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
      cliPath: 'os.process.kill',
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
      cliPath: 'os.process.detail',
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
      cliPath: 'os.process.connections',
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

    // ── Network (web) ────────────────────────────────────────────────────────
    OsToolDefinition(
      name: 'web_search',
      cliPath: 'web.search',
      description:
          'Search the web and return a list of relevant results (title, URL, snippet). '
          'Use when the user asks to look something up, find information, or research a topic online.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': 'The search query',
          },
          'limit': {
            'type': 'integer',
            'description': 'Maximum number of results to return (default: 10)',
          },
        },
        'required': ['query'],
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _all,
      category: 'network',
      configSpec: [
        CliConfigField(
          key: 'api_key',
          label: 'API Key',
          description:
              'Brave Search API key (starts with BSA...) or Tavily API key (starts with tvly-). '
              'The provider is auto-detected from the key prefix.',
          type: CliConfigFieldType.apiKey,
          required: true,
        ),
        CliConfigField(
          key: 'max_results',
          label: 'Max Results',
          description: 'Maximum number of search results to return (default: 10).',
          type: CliConfigFieldType.integer,
          defaultValue: 10,
        ),
        CliConfigField(
          key: 'timeout',
          label: 'Timeout (seconds)',
          description: 'Request timeout in seconds (default: 30).',
          type: CliConfigFieldType.integer,
          defaultValue: 30,
        ),
      ],
    ),
    OsToolDefinition(
      name: 'web_fetch',
      cliPath: 'web.fetch',
      description:
          'Fetch the content of a URL and return it as plain text or markdown. '
          'Use when the user asks to read, summarize, or extract information from a specific webpage.',
      parameterSchema: {
        'type': 'object',
        'properties': {
          'url': {
            'type': 'string',
            'description': 'The URL to fetch',
          },
          'format': {
            'type': 'string',
            'enum': ['text', 'markdown', 'html'],
            'description': 'Output format (default: markdown)',
          },
          'timeout': {
            'type': 'integer',
            'description': 'Request timeout in seconds (default: 30)',
          },
        },
        'required': ['url'],
      },
      defaultRiskLevel: 'safe',
      supportedPlatforms: _all,
      category: 'network',
    ),
  ];

  // ---------------------------------------------------------------------------
  // cliPath ↔ name 双向映射（懒初始化）
  // ---------------------------------------------------------------------------

  late final Map<String, String> _cliPathToName = {
    for (final t in tools) t.cliPath: t.name,
  };

  late final Map<String, String> _nameToCli = {
    for (final t in tools) t.name: t.cliPath,
  };

  /// 从 cliPath 解析为内部 name（用于 runTool 分派）。
  /// 找不到则原样返回，保持向后兼容。
  String resolveToolName(String cliPathOrName) =>
      _cliPathToName[cliPathOrName] ?? cliPathOrName;

  /// 从内部 name 获取 cliPath。找不到则原样返回。
  String toCliPath(String name) => _nameToCli[name] ?? name;

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

  /// All tool names (internal).
  Set<String> get allToolNames => tools.map((t) => t.name).toSet();

  /// All CLI paths.
  Set<String> get allCliPaths => tools.map((t) => t.cliPath).toSet();

  /// Tool names supported on the current platform.
  Set<String> get platformToolNames =>
      tools
          .where((t) => t.supportedPlatforms.contains(currentPlatform))
          .map((t) => t.name)
          .toSet();

  /// Whether [toolName] is a known OS tool (accepts name or cliPath).
  bool isOsTool(String toolName) =>
      tools.any((t) => t.name == toolName || t.cliPath == toolName);

  /// Lookup a definition by name or cliPath, or null.
  OsToolDefinition? getDefinition(String toolNameOrCliPath) {
    for (final t in tools) {
      if (t.name == toolNameOrCliPath || t.cliPath == toolNameOrCliPath) {
        return t;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // LLM tool formats (filtered by platform + enabled set)
  // ---------------------------------------------------------------------------

  /// Returns OS tools in OpenAI function-calling format, filtered by
  /// current platform and the user-enabled set.
  ///
  /// LLM 看到的 function name 是 [cliPath]（如 `os.shell.exec`）。
  List<Map<String, dynamic>> openAITools({Set<String>? enabledTools}) {
    return _filteredTools(enabledTools)
        .map((t) => <String, dynamic>{
              'type': 'function',
              'function': {
                'name': t.cliPath,
                'description': t.description,
                'parameters': t.parameterSchema,
              },
            })
        .toList();
  }

  /// Returns OS tools in Claude (Anthropic) format.
  ///
  /// LLM 看到的 tool name 是 [cliPath]（如 `os.shell.exec`）。
  List<Map<String, dynamic>> claudeTools({Set<String>? enabledTools}) {
    return _filteredTools(enabledTools)
        .map((t) => <String, dynamic>{
              'name': t.cliPath,
              'description': t.description,
              'input_schema': t.parameterSchema,
            })
        .toList();
  }

  /// System prompt suffix describing available OS tools.
  String systemPromptSuffix(Set<String> enabledTools) =>
      systemPromptSuffixLayered(enabledTools, 'summary');

  /// Layered system prompt suffix for OS tools.
  ///
  /// [level] controls verbosity:
  /// - `'names_only'`: Only tool CLI paths — minimal context.
  /// - `'summary'`: CLI path + one-liner (default, ~50 % tokens vs full).
  /// - `'full'`: Complete description without truncation.
  String systemPromptSuffixLayered(Set<String> enabledTools, String level) {
    final filtered = _filteredTools(enabledTools);
    if (filtered.isEmpty) return '';
    final toolLines = filtered.map((t) {
      switch (level) {
        case 'names_only':
          return '- ${t.cliPath}';
        case 'full':
          return '- ${t.cliPath}: ${t.description}';
        default: // 'summary'
          return '- ${t.cliPath}: ${t.description.split('.').first.trim().toLowerCase()}';
      }
    }).join('\n');
    if (level == 'names_only') {
      return '''

You also have access to OS-level tools that let you operate the local machine.
Available OS tools:
$toolLines
For full details on any tool, call: shepaw tools os.detail --name <tool-name>
IMPORTANT: These tools execute real actions on the user's device. Always confirm destructive operations.''';
    }
    return '''

You also have access to OS-level tools that let you operate the local machine.
Use them when the user asks you to interact with files, run commands, take screenshots, etc.
Available OS tools:
$toolLines
IMPORTANT: These tools execute real actions on the user's device. Always confirm destructive operations.
For file/command operations, prefer using these tools over describing steps in text.''';
  }

  /// Returns a compact CLI-reference block that tells agents OS tools exist,
  /// without enumerating all tool names or discovery commands.
  ///
  /// This is the default for non-She agents ([osToolsMode] == 'cli_reference').
  /// Discovery commands (`tools os.list`, `tools os.detail`) are intentionally
  /// omitted here — they are already listed in the Agent Meta CLI block
  /// (`_buildAgentMetaCliBlock`) which is injected later in the prompt.
  String systemPromptCliReference(Set<String> enabledTools) {
    final filtered = _filteredTools(enabledTools);
    if (filtered.isEmpty) return '';
    final count = filtered.length;
    return '''

You have access to $count OS-level tools that let you operate the local machine (files, terminal, screenshots, clipboard, etc.).
IMPORTANT: These tools execute real actions on the user's device. Always confirm destructive operations.''';
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
    'network': 'Network & Web',
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
      // enabledTools 可以是 name 或 cliPath
      if (enabledTools != null &&
          !enabledTools.contains(t.name) &&
          !enabledTools.contains(t.cliPath)) {
        return false;
      }
      return true;
    });
  }
}

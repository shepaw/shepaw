/// CLI Tool Registry — runtime discovery, installation, and execution of
/// external CLI tools.
///
/// External CLI tools live under `~/shepaw/cli-tools/`. Each tool is a
/// subdirectory containing a `cli-tool.json` manifest and a handler
/// (script or binary).
///
/// Communication protocol: stdin/stdout JSON.
/// - Input:  `{"command": "<name>", "flags": {...}}`
/// - Output: `{"success": true, "data": {...}}` or
///           `{"success": false, "error": "..."}`
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cli_tool_definition.dart';
import 'logger_service.dart';

/// Thrown when installing a CLI tool whose namespace conflicts with an existing
/// tool or a built-in namespace.
class CliToolConflictException implements Exception {
  final String namespace;
  final String displayName;
  CliToolConflictException(this.namespace, this.displayName);

  @override
  String toString() =>
      'CliToolConflictException: tool "$displayName" (namespace "$namespace") already exists';
}

/// Central registry for external CLI tools.
///
/// Mirrors [SkillRegistry] but for executable CLI tools rather than
/// markdown-based skill instructions.
class CliToolRegistry {
  CliToolRegistry._();
  static final CliToolRegistry instance = CliToolRegistry._();

  static const _tag = 'CliToolRegistry';

  String _directoryPath = '';
  List<CliToolDefinition> _tools = [];

  /// Built-in namespace names that external tools must not shadow.
  static const _reservedNamespaces = {
    'context',
    'chat',
    'tools',
    'skills',
    'meta',
    'help',
  };

  /// Absolute path to the cli-tools directory.
  String get directoryPath => _directoryPath;

  /// All currently loaded tool definitions.
  List<CliToolDefinition> get tools => List.unmodifiable(_tools);

  /// All tool namespace names.
  Set<String> get allNamespaces => _tools.map((t) => t.namespace).toSet();

  // ---------------------------------------------------------------------------
  // Platform detection
  // ---------------------------------------------------------------------------

  String get _currentPlatform {
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return 'unknown';
  }

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  /// Resolves the default cli-tools directory under the app's documents path
  /// and performs the initial scan. Call once at app startup.
  Future<void> initialize() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final toolsDir = Directory(p.join(docsDir.path, 'shepaw', 'cli-tools'));
    if (!await toolsDir.exists()) {
      await toolsDir.create(recursive: true);
    }
    _directoryPath = toolsDir.path;
    await rescan();
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  /// Re-scans the cli-tools directory for tool packages (subdirectories
  /// containing `cli-tool.json`).
  Future<void> rescan() async {
    _tools = [];
    if (_directoryPath.isEmpty) return;

    final dir = Directory(_directoryPath);
    if (!await dir.exists()) return;

    try {
      final seenNamespaces = <String>{};
      final entries = dir.listSync();
      final subDirs = entries.whereType<Directory>().toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));

      for (final subDir in subDirs) {
        final def = await _parseToolDirectory(subDir);
        if (def == null) continue;

        // Skip reserved namespaces
        if (_reservedNamespaces.contains(def.namespace)) {
          LoggerService().warning(
            'Skipping tool "${def.displayName}": namespace "${def.namespace}" '
            'conflicts with built-in namespace',
            tag: _tag,
          );
          continue;
        }

        // Skip duplicate namespaces
        if (seenNamespaces.contains(def.namespace)) {
          LoggerService().warning(
            'Skipping duplicate tool namespace "${def.namespace}" '
            'in ${subDir.path}',
            tag: _tag,
          );
          continue;
        }

        // Platform filter
        if (!def.supportedPlatforms.contains(_currentPlatform)) {
          LoggerService().info(
            'Skipping tool "${def.displayName}": not supported on '
            '$_currentPlatform',
            tag: _tag,
          );
          continue;
        }

        _tools.add(def);
        seenNamespaces.add(def.namespace);
      }

      LoggerService().info(
        'Loaded ${_tools.length} external CLI tool(s)',
        tag: _tag,
      );
    } catch (e) {
      LoggerService().error('Error scanning cli-tools directory: $e',
          tag: _tag);
    }
  }

  /// Parse a single tool directory.
  Future<CliToolDefinition?> _parseToolDirectory(Directory dir) async {
    try {
      final manifestFile = File(p.join(dir.path, 'cli-tool.json'));
      if (!await manifestFile.exists()) return null;

      final content = await manifestFile.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final def = CliToolDefinition.fromJson(json, dir.path);

      // Validate handler exists
      final handlerFile = File(def.handlerPath);
      if (!await handlerFile.exists()) {
        LoggerService().warning(
          'Tool "${def.displayName}": handler not found at ${def.handlerPath}',
          tag: _tag,
        );
        return null;
      }

      return def;
    } catch (e) {
      LoggerService().error(
        'Error parsing tool in ${dir.path}: $e',
        tag: _tag,
      );
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Installation
  // ---------------------------------------------------------------------------

  /// Installs a CLI tool from a ZIP file.
  ///
  /// The ZIP must contain a `cli-tool.json` manifest at the root or one level
  /// deep. The tool is extracted to `<cli-tools>/<namespace>/`.
  ///
  /// Throws [CliToolConflictException] if the namespace already exists and
  /// [overwrite] is false.
  Future<CliToolDefinition> installFromZip(
    String zipPath, {
    bool overwrite = false,
  }) async {
    if (_directoryPath.isEmpty) {
      throw Exception('CLI tool registry not initialized');
    }

    final zipFile = File(zipPath);
    if (!await zipFile.exists()) {
      throw ArgumentError('ZIP file not found: $zipPath');
    }

    // Extract to temp dir
    final tempDir = await Directory.systemTemp.createTemp('cli_tool_');
    try {
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive) {
        final filePath = p.join(tempDir.path, file.name);
        if (file.isFile) {
          final outFile = File(filePath);
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);
        } else {
          await Directory(filePath).create(recursive: true);
        }
      }

      // Find cli-tool.json (root or one level deep)
      final manifest = await _findManifest(tempDir);
      if (manifest == null) {
        throw Exception('No cli-tool.json found in the ZIP archive');
      }

      // Parse manifest
      final json =
          jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;
      final namespace = json['namespace'] as String?;
      if (namespace == null || namespace.isEmpty) {
        throw Exception('cli-tool.json must contain a "namespace" field');
      }

      // Conflict check
      if (_reservedNamespaces.contains(namespace)) {
        throw CliToolConflictException(
            namespace, json['displayName'] as String? ?? namespace);
      }
      final existing = getDefinition(namespace);
      if (existing != null && !overwrite) {
        throw CliToolConflictException(
            namespace, json['displayName'] as String? ?? namespace);
      }

      // Destination: <cli-tools>/<namespace>/
      final destDir = Directory(p.join(_directoryPath, namespace));
      if (await destDir.exists()) {
        await destDir.delete(recursive: true);
      }
      await destDir.create(recursive: true);

      // Copy from manifest's directory
      final sourceDir = manifest.parent;
      await _copyDirectory(sourceDir, destDir);

      // Ensure handler is executable
      final def = CliToolDefinition.fromJson(json, destDir.path);
      await _ensureExecutable(def.handlerPath);

      await rescan();
      final newDef = getDefinition(namespace);
      if (newDef == null) {
        throw Exception('Installed tool not found after rescan');
      }
      return newDef;
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Downloads and installs a CLI tool from a URL.
  ///
  /// Only `.zip` URLs are supported.
  Future<CliToolDefinition> installFromUrl(
    String url, {
    bool overwrite = false,
    void Function(int received, int total)? onProgress,
  }) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError('Invalid URL: $url');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('Only http/https protocols are supported');
    }

    final pathLower = uri.path.toLowerCase();
    if (!pathLower.endsWith('.zip')) {
      throw ArgumentError('Only .zip files are supported for CLI tool install');
    }

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(minutes: 5),
    ));

    final tempDir = await Directory.systemTemp.createTemp('cli_tool_url_');
    final tempFile = File('${tempDir.path}/download.zip');
    try {
      await dio.download(url, tempFile.path, onReceiveProgress: onProgress);
      return await installFromZip(tempFile.path, overwrite: overwrite);
    } on DioException catch (e) {
      final msg = switch (e.type) {
        DioExceptionType.connectionTimeout => 'Connection timeout',
        DioExceptionType.receiveTimeout => 'Receive timeout',
        DioExceptionType.badResponse =>
          'HTTP ${e.response?.statusCode}: ${e.response?.statusMessage}',
        DioExceptionType.cancel => 'Download cancelled',
        _ => 'Network error: ${e.message}',
      };
      throw Exception(msg);
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
      dio.close();
    }
  }

  /// Uninstalls a CLI tool by removing its directory and rescanning.
  Future<void> uninstall(String namespace) async {
    final def = getDefinition(namespace);
    if (def == null) {
      throw Exception('Tool with namespace "$namespace" not found');
    }

    final dir = Directory(def.directoryPath);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }

    await rescan();
  }

  // ---------------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------------

  /// Whether [namespace] is a registered external CLI tool.
  bool isCliTool(String namespace) =>
      _tools.any((t) => t.namespace == namespace);

  /// Lookup a definition by namespace, or null.
  CliToolDefinition? getDefinition(String namespace) {
    for (final t in _tools) {
      if (t.namespace == namespace) return t;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Command execution
  // ---------------------------------------------------------------------------

  /// Execute a command on an external CLI tool.
  ///
  /// Spawns the tool's handler process, sends the request via stdin as JSON,
  /// and reads the response from stdout.
  ///
  /// Returns a JSON-serializable map with the result.
  Future<Map<String, dynamic>> executeCommand(
    String namespace,
    String command,
    Map<String, String> flags, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final tool = getDefinition(namespace);
    if (tool == null) {
      return {'error': 'Unknown tool namespace: $namespace'};
    }

    final cmd = tool.commands[command];
    if (cmd == null) {
      return {
        'error': 'Unknown command: $command',
        'available_commands': tool.commands.keys.toList(),
      };
    }

    // Build request JSON
    final request = jsonEncode({
      'command': command,
      'flags': flags,
    });

    try {
      // Start process
      final List<String> execArgs;
      final String executable;

      if (tool.handlerType == 'binary') {
        executable = tool.handlerPath;
        execArgs = [];
      } else {
        // script — use shell to interpret
        executable = tool.handlerPath;
        execArgs = [];
      }

      final process = await Process.start(
        executable,
        execArgs,
        workingDirectory: tool.directoryPath,
      );

      // Write request to stdin
      process.stdin.writeln(request);
      await process.stdin.close();

      // Read stdout and stderr
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();

      // Wait for exit with timeout
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process.kill(ProcessSignal.sigterm);
          return -1;
        },
      );

      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;

      if (exitCode == -1) {
        return {
          'error': 'Tool execution timed out after ${timeout.inSeconds}s',
          'namespace': namespace,
          'command': command,
        };
      }

      if (exitCode != 0) {
        return {
          'error': 'Tool exited with code $exitCode',
          'stderr': stderr.isNotEmpty ? stderr : null,
          'stdout': stdout.isNotEmpty ? stdout : null,
        };
      }

      // Parse JSON response
      if (stdout.trim().isEmpty) {
        return {
          'success': true,
          'data': null,
          'message': 'Command completed with no output',
        };
      }

      try {
        final result = jsonDecode(stdout.trim());
        if (result is Map<String, dynamic>) return result;
        return {'success': true, 'data': result};
      } catch (_) {
        // Non-JSON output — return as plain text
        return {'success': true, 'output': stdout.trim()};
      }
    } catch (e) {
      return {
        'error': 'Failed to execute tool: $e',
        'namespace': namespace,
        'command': command,
      };
    }
  }

  // ---------------------------------------------------------------------------
  // LLM tool schema helpers
  // ---------------------------------------------------------------------------

  /// Returns a description fragment for external tools, suitable for
  /// appending to the ShepawCLI tool description.
  String toolDescriptionSuffix() {
    if (_tools.isEmpty) return '';

    final parts = _tools.map((t) {
      final cmds = t.commands.keys.join(', ');
      return '[EXT] ${t.namespace} ($cmds)';
    }).join('; ');

    return ' External tools: $parts.';
  }

  /// Returns namespace enum values for external tools.
  List<String> externalNamespaceNames() =>
      _tools.map((t) => t.namespace).toList();

  /// Returns a subcommand description fragment for external tools.
  String externalSubcommandDescription() {
    if (_tools.isEmpty) return '';

    return _tools.map((t) {
      final cmds = t.commands.entries
          .map((e) => e.key)
          .join('|');
      return '${t.namespace}: $cmds';
    }).join('; ');
  }

  // ---------------------------------------------------------------------------
  // File helpers
  // ---------------------------------------------------------------------------

  /// Find cli-tool.json in root or one level deep.
  Future<File?> _findManifest(Directory dir) async {
    // Check root
    final rootManifest = File(p.join(dir.path, 'cli-tool.json'));
    if (await rootManifest.exists()) return rootManifest;

    // Check one level deep
    for (final entry in dir.listSync()) {
      if (entry is Directory) {
        final nested = File(p.join(entry.path, 'cli-tool.json'));
        if (await nested.exists()) return nested;
      }
    }

    return null;
  }

  /// Recursively copy a directory.
  Future<void> _copyDirectory(Directory source, Directory dest) async {
    for (final entity in source.listSync()) {
      final newPath = p.join(dest.path, p.basename(entity.path));
      if (entity is File) {
        await entity.copy(newPath);
      } else if (entity is Directory) {
        final newDir = Directory(newPath);
        await newDir.create(recursive: true);
        await _copyDirectory(entity, newDir);
      }
    }
  }

  /// Ensure a file is executable (chmod +x on POSIX systems).
  Future<void> _ensureExecutable(String path) async {
    if (Platform.isWindows) return;
    try {
      await Process.run('chmod', ['+x', path]);
    } catch (_) {}
  }
}

import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// File operations namespace — read, write, delete, move, list
///
///   shepaw os file.read --path /tmp/test.txt [--max_bytes 10240]
///   shepaw os file.write --path /tmp/test.txt --content "hello" [--append true]
///   shepaw os file.delete --path /tmp/old.txt [--recursive true]
///   shepaw os file.move --source /tmp/a.txt --destination /tmp/b.txt
///   shepaw os file.list --path /tmp [--show_hidden true] [--detail true]
class FileNamespace extends CliNamespace {
  static final instance = FileNamespace._();
  FileNamespace._();

  @override
  String get namespace => 'file';

  @override
  String get description => 'File operations (read, write, delete, move, list)';

  @override
  String get usage => 'shepaw os file.<action> [flags]';

  @override
  Map<String, CliCommand> get commands {
    final cmds = [
      _FileReadCommand(),
      _FileWriteCommand(),
      _FileDeleteCommand(),
      _FileMoveCommand(),
      _FileListCommand(),
    ];
    return {
      for (final cmd in cmds)
        if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
    };
  }
}

// ── file_read ────────────────────────────────────────────────────────────────

class _FileReadCommand extends CliCommand {
  @override
  String get name => 'read';

  @override
  String get description => 'Read the contents of a file.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android'};

  @override
  String get usage =>
      'shepaw os file.read --path <path> [--max_bytes <bytes>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('file_read', {
      if (flags['path'] != null) 'path': flags['path']!,
      if (flags['max_bytes'] != null)
        'max_bytes': int.tryParse(flags['max_bytes']!) ?? flags['max_bytes'],
    });
  }
}

// ── file_write ───────────────────────────────────────────────────────────────

class _FileWriteCommand extends CliCommand {
  @override
  String get name => 'write';

  @override
  String get description =>
      'Write content to a file. Creates the file if it does not exist.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android'};

  @override
  String get usage =>
      'shepaw os file.write --path <path> --content <content> [--append true]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('file_write', {
      if (flags['path'] != null) 'path': flags['path']!,
      if (flags['content'] != null) 'content': flags['content']!,
      if (flags['append'] != null)
        'append': flags['append'] == 'true' || flags['append'] == '1',
    });
  }
}

// ── file_delete ──────────────────────────────────────────────────────────────

class _FileDeleteCommand extends CliCommand {
  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a file or directory.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android'};

  @override
  String get usage =>
      'shepaw os file.delete --path <path> [--recursive true]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('file_delete', {
      if (flags['path'] != null) 'path': flags['path']!,
      if (flags['recursive'] != null)
        'recursive': flags['recursive'] == 'true' || flags['recursive'] == '1',
    });
  }
}

// ── file_move ────────────────────────────────────────────────────────────────

class _FileMoveCommand extends CliCommand {
  @override
  String get name => 'move';

  @override
  String get description => 'Move or rename a file or directory.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows', 'android'};

  @override
  String get usage =>
      'shepaw os file.move --source <source> --destination <destination>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('file_move', {
      if (flags['source'] != null) 'source': flags['source']!,
      if (flags['destination'] != null) 'destination': flags['destination']!,
    });
  }
}

// ── file_list ────────────────────────────────────────────────────────────────

class _FileListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List the contents of a directory.';

  @override
  String get usage =>
      'shepaw os file.list --path <path> [--show_hidden true] [--detail true]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('file_list', {
      if (flags['path'] != null) 'path': flags['path']!,
      if (flags['show_hidden'] != null)
        'show_hidden':
            flags['show_hidden'] == 'true' || flags['show_hidden'] == '1',
      if (flags['detail'] != null)
        'detail': flags['detail'] == 'true' || flags['detail'] == '1',
    });
  }
}

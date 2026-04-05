import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// Process management namespace — list, kill, detail, network connections
///
///   shepaw os process.list [--filter <name>] [--sort_by cpu|memory|pid|name] [--limit 50]
///   shepaw os process.kill --pid <pid> [--force true]
///   shepaw os process.detail --pid <pid>
///   shepaw os process.connections [--pid <pid>]
class ProcessNamespace extends CliNamespace {
  static final instance = ProcessNamespace._();
  ProcessNamespace._();

  @override
  String get namespace => 'process';

  @override
  String get description => 'Process management (list, kill, detail, connections)';

  @override
  String get usage => 'shepaw os process.<action> [flags]';

  /// 进程管理仅支持桌面平台
  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  Map<String, CliCommand> get commands {
    final cmds = [
      _ProcessListCommand(),
      _ProcessKillCommand(),
      _ProcessDetailCommand(),
      _NetworkConnectionsCommand(),
    ];
    return {
      for (final cmd in cmds)
        if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
    };
  }
}

// ── process_list ─────────────────────────────────────────────────────────────

class _ProcessListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List running processes. Supports filtering by name, sorting, and limiting results.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage =>
      'shepaw os process.list [--filter <name>] [--sort_by cpu|memory|pid|name] [--limit 50]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('process_list', {
      if (flags['filter'] != null) 'filter': flags['filter']!,
      if (flags['sort_by'] != null) 'sort_by': flags['sort_by']!,
      if (flags['limit'] != null)
        'limit': int.tryParse(flags['limit']!) ?? flags['limit'],
    });
  }
}

// ── process_kill ─────────────────────────────────────────────────────────────

class _ProcessKillCommand extends CliCommand {
  @override
  String get name => 'kill';

  @override
  String get description =>
      'Kill a process by PID. Sends SIGTERM by default, or SIGKILL with --force true. '
      'Protected system processes cannot be killed.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage =>
      'shepaw os process.kill --pid <pid> [--force true]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('process_kill', {
      if (flags['pid'] != null)
        'pid': int.tryParse(flags['pid']!) ?? flags['pid'],
      if (flags['force'] != null)
        'force': flags['force'] == 'true' || flags['force'] == '1',
    });
  }
}

// ── process_detail ───────────────────────────────────────────────────────────

class _ProcessDetailCommand extends CliCommand {
  @override
  String get name => 'detail';

  @override
  String get description =>
      'Get detailed information about a specific process by PID, '
      'including CPU, memory, command line, and open files.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage => 'shepaw os process.detail --pid <pid>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('process_detail', {
      if (flags['pid'] != null)
        'pid': int.tryParse(flags['pid']!) ?? flags['pid'],
    });
  }
}

// ── network_connections ──────────────────────────────────────────────────────

class _NetworkConnectionsCommand extends CliCommand {
  @override
  String get name => 'connections';

  @override
  String get description =>
      'List active network connections (TCP/UDP). '
      'Optionally filter by a specific process PID.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage => 'shepaw os process.connections [--pid <pid>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('network_connections', {
      if (flags['pid'] != null)
        'pid': int.tryParse(flags['pid']!) ?? flags['pid'],
    });
  }
}

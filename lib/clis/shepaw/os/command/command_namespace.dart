import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// Command & System namespace — shell execution and system info
///
///   shepaw os command.exec --command "ls -la"
///   shepaw os command.sysinfo [--category overview|cpu|memory|disk|network|battery|displays]
class CommandNamespace extends CliNamespace {
  static final instance = CommandNamespace._();
  CommandNamespace._();

  @override
  String get namespace => 'command';

  @override
  String get description => 'Command execution and system information';

  @override
  String get usage => 'shepaw os command.<action> [flags]';

  @override
  Map<String, CliCommand> get commands {
    final cmds = [_ShellExecCommand(), _SysinfoCommand()];
    return {
      for (final cmd in cmds)
        if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
    };
  }
}

// ── shell_exec ───────────────────────────────────────────────────────────────

class _ShellExecCommand extends CliCommand {
  @override
  String get name => 'exec';

  @override
  String get description =>
      'Execute a shell command on the local machine. '
      'Use for running terminal commands, scripts, and system utilities.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage =>
      'shepaw os command.exec --command <command> [--timeout <secs>] [--working_dir <dir>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('shell_exec', {
      if (flags['command'] != null) 'command': flags['command']!,
      if (flags['timeout'] != null)
        'timeout': int.tryParse(flags['timeout']!) ?? flags['timeout'],
      if (flags['working_dir'] != null) 'working_dir': flags['working_dir']!,
    });
  }
}

// ── system_info ──────────────────────────────────────────────────────────────

class _SysinfoCommand extends CliCommand {
  @override
  String get name => 'sysinfo';

  @override
  String get description =>
      'Get system information (OS, CPU, memory, disk, etc.).';

  @override
  String get usage =>
      'shepaw os command.sysinfo [--category overview|cpu|memory|disk|network|battery|displays]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('system_info', {
      if (flags['category'] != null) 'category': flags['category']!,
    });
  }
}

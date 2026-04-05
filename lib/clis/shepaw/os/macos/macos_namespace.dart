import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// macOS namespace — AppleScript execution (macOS only)
///
///   shepaw os macos.exec --script 'tell app "Finder" to activate'
class MacosNamespace extends CliNamespace {
  static final instance = MacosNamespace._();
  MacosNamespace._();

  @override
  String get namespace => 'macos';

  @override
  String get description => 'macOS-only operations (AppleScript)';

  @override
  String get usage => 'shepaw os macos.<action> [flags]';

  /// MacOS namespace 和其命令仅在 macOS 上可用
  @override
  Set<String> get supportedPlatforms => const {'macos'};

  @override
  Map<String, CliCommand> get commands {
    final cmds = [_ApplescriptCommand()];
    return {
      for (final cmd in cmds)
        if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
    };
  }
}

// ── applescript_exec ─────────────────────────────────────────────────────────

class _ApplescriptCommand extends CliCommand {
  @override
  String get name => 'exec';

  @override
  String get description =>
      'Execute an AppleScript. Useful for automating macOS applications and system features.';

  @override
  Set<String> get supportedPlatforms => const {'macos'};

  @override
  String get usage =>
      "shepaw os macos.exec --script 'tell app \"Finder\" to activate'";

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('applescript_exec', {
      if (flags['script'] != null) 'script': flags['script']!,
    });
  }
}

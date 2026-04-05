import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// App & Browser namespace — open applications, URLs, take screenshots
///
///   shepaw os app.open --app_name Safari
///   shepaw os app.url --url https://dart.dev
///   shepaw os app.screenshot [--region full|window|x,y,w,h] [--save_path <path>]
class AppNamespace extends CliNamespace {
  static final instance = AppNamespace._();
  AppNamespace._();

  @override
  String get namespace => 'app';

  @override
  String get description => 'Application and browser operations';

  @override
  String get usage => 'shepaw os app.<action> [flags]';

  @override
  Map<String, CliCommand> get commands {
    final cmds = [_AppOpenCommand(), _UrlOpenCommand(), _ScreenshotCommand()];
    return {
      for (final cmd in cmds)
        if (cmd.supportedPlatforms.contains(currentPlatformName)) cmd.name: cmd,
    };
  }
}

// ── app_open ─────────────────────────────────────────────────────────────────

class _AppOpenCommand extends CliCommand {
  @override
  String get name => 'open';

  @override
  String get description => 'Open an application by name.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage => "shepaw os app.open --app_name <name>";

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('app_open', {
      if (flags['app_name'] != null) 'app_name': flags['app_name']!,
    });
  }
}

// ── url_open ─────────────────────────────────────────────────────────────────

class _UrlOpenCommand extends CliCommand {
  @override
  String get name => 'url';

  @override
  String get description => 'Open a URL in the default browser.';

  @override
  String get usage => 'shepaw os app.url --url <url>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('url_open', {
      if (flags['url'] != null) 'url': flags['url']!,
    });
  }
}

// ── screenshot ───────────────────────────────────────────────────────────────

class _ScreenshotCommand extends CliCommand {
  @override
  String get name => 'screenshot';

  @override
  String get description => 'Take a screenshot of the screen.';

  @override
  Set<String> get supportedPlatforms => const {'macos', 'linux', 'windows'};

  @override
  String get usage =>
      'shepaw os app.screenshot [--region full|window|x,y,w,h] [--save_path <path>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('screenshot', {
      if (flags['region'] != null) 'region': flags['region']!,
      if (flags['save_path'] != null) 'save_path': flags['save_path']!,
    });
  }
}

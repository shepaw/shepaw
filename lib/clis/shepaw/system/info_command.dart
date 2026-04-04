import '../../cli_base.dart';

/// Returns basic system information.
class InfoCommand extends CliCommand {
  @override
  String get name => 'info';

  @override
  String get description => 'Return basic app information (version, platform, current time)';

  @override
  String get usage => 'shepaw meta system.info';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final now = DateTime.now();
    return {
      'app': 'ShePaw',
      'timestamp': now.toIso8601String(),
      'platform': _platform,
    };
  }

  String get _platform {
    // Detect platform (simplified; can be enhanced with dart:io)
    try {
      return 'darwin'; // Example; actual implementation would check host platform
    } catch (e) {
      return 'unknown';
    }
  }
}

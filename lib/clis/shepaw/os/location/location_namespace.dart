import '../../../cli_base.dart';
import '../os_executor.dart' as os_exec;

/// Location namespace — on-demand device location (no background tracking)
///
///   shepaw os location.get [--accuracy high] [--reverse_geocode true] [--timeout 15]
///   shepaw os location.status
class LocationNamespace extends CliNamespace {
  static final instance = LocationNamespace._();
  LocationNamespace._();

  @override
  String get namespace => 'location';

  @override
  String get description =>
      'Device location (current position and permission status)';

  @override
  String get usage => 'shepaw os location.<action> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'get': _LocationGetCommand(),
        'status': _LocationStatusCommand(),
      };
}

class _LocationGetCommand extends CliCommand {
  @override
  String get name => 'get';

  @override
  String get description =>
      'Get the device\'s current geographic location. '
      'Returns coordinates and, when possible, a reverse-geocoded place name. '
      'Requires user permission. Does not track location in the background.';

  @override
  String get usage =>
      'shepaw os location.get [--accuracy lowest|low|medium|high|best] '
      '[--reverse_geocode true|false] [--timeout <secs>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('location_get', {
      if (flags['accuracy'] != null) 'accuracy': flags['accuracy']!,
      if (flags['reverse_geocode'] != null)
        'reverse_geocode':
            flags['reverse_geocode'] == 'true' || flags['reverse_geocode'] == '1',
      if (flags['timeout'] != null)
        'timeout': int.tryParse(flags['timeout']!) ?? flags['timeout'],
    });
  }
}

class _LocationStatusCommand extends CliCommand {
  @override
  String get name => 'status';

  @override
  String get description =>
      'Check whether location services and permission are available. '
      'Does not read GPS coordinates.';

  @override
  String get usage => 'shepaw os location.status';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return await os_exec.runTool('location_status', {});
  }
}

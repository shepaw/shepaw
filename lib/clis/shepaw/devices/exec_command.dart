import '../../cli_base.dart';
import '../../../identity/services/device_rpc_service.dart';

/// 在指定自有设备上远程执行 shepaw CLI 命令。
class DevicesExecCommand extends CliCommand {
  @override
  String get name => 'exec';

  @override
  String get description =>
      'Run shepaw CLI on a remote owned device (--device <id> --command "shepaw ...")';

  @override
  String get usage =>
      'shepaw devices exec --device <device_id> --command "shepaw context agents.list"';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'device': {
        'description': 'Target device_id',
        'required': true,
        'type': 'string',
      },
      'command': {
        'description': 'Full shepaw command line to run on the remote device',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final deviceId = flags['device'];
    final command = flags['command'];
    if (deviceId == null || deviceId.isEmpty) {
      return {'error': 'missing_device', 'hint': usage};
    }
    if (command == null || command.isEmpty) {
      return {'error': 'missing_command', 'hint': usage};
    }

    try {
      final result = await DeviceRpcService.instance.call(
        targetDeviceId: deviceId,
        method: 'cli.exec',
        params: {'command': command},
      );
      return {'device_id': deviceId, ...result};
    } catch (e) {
      return {'error': e.toString(), 'device_id': deviceId};
    }
  }
}

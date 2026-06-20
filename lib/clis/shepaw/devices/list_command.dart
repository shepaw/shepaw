import '../../cli_base.dart';
import '../../../identity/services/account_identity_service.dart';

/// 列出账号域内已信任的自有设备。
class DevicesListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List owned devices in this account';

  @override
  String get usage => 'shepaw devices list';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    await AccountIdentityService.instance.ensureInitialized();
    final devices = await AccountIdentityService.instance.ownedDevices();
    final list = devices
        .map((d) => {
              'device_id': d.deviceId,
              'device_name': d.deviceName,
              'role': d.role.wireValue,
              'is_local': d.isLocal,
              'fingerprint': d.fingerprint,
              'last_seen_at': d.lastSeenAt,
            })
        .toList();
    return {'devices': list, 'count': list.length};
  }
}

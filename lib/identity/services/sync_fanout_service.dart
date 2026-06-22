import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'sync_protocol_service.dart';

/// Primary 设备本地写入后，向已关联 App/Backup 设备 fan-out 同步事件。
class SyncFanoutService {
  SyncFanoutService._();

  static Future<void> fanout(SyncEvent event) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) return;
    await SyncProtocolService.instance.pushEventsToPeers([event]);
  }

  static Future<void> fanoutMany(List<SyncEvent> events) async {
    if (events.isEmpty) return;
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) return;
    await SyncProtocolService.instance.pushEventsToPeers(events);
  }
}

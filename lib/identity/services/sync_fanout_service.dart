import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'sync_protocol_service.dart';

/// Primary 设备本地写入后，向已关联 App/Backup 设备 fan-out 同步事件。
class SyncFanoutService {
  SyncFanoutService._();

  static Future<void> fanout(SyncEvent event) async {
    if (!await AccountIdentityService.instance.isCanonicalPrimary()) return;
    await SyncProtocolService.instance.pushEventsToPeers([event]);
  }

  static Future<void> fanoutMany(List<SyncEvent> events) async {
    if (events.isEmpty) return;
    if (!await AccountIdentityService.instance.isCanonicalPrimary()) return;
    await SyncProtocolService.instance.pushEventsToPeers(events);
  }
}

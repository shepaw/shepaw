import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'sync_protocol_service.dart';

/// Primary 设备本地写入后，向已关联 App/Backup 设备 fan-out 同步事件。
class SyncFanoutService {
  SyncFanoutService._();

  static const _tag = 'SyncFanout';
  static final _log = LoggerService();

  static Future<void> fanout(SyncEvent event) async {
    if (!await _fanoutAllowed()) return;
    await SyncProtocolService.instance.pushEventsToPeers([event]);
  }

  static Future<void> fanoutMany(List<SyncEvent> events) async {
    if (events.isEmpty) return;
    if (!await _fanoutAllowed()) return;
    await SyncProtocolService.instance.pushEventsToPeers(events);
  }

  static Future<bool> _fanoutAllowed() async {
    if (!await AccountIdentityService.instance.isCanonicalPrimary()) return false;

    final local = await AccountIdentityService.instance.localDevice();
    final elected = await AccountIdentityService.instance.userElectedPrimaryDeviceId();
    if (elected != null &&
        elected.isNotEmpty &&
        local != null &&
        elected != local.deviceId) {
      _log.warning('Skipping fanout: local is not user-elected primary', tag: _tag);
      return false;
    }

    final owned = await AccountIdentityService.instance.ownedDevices();
    final primaryCount = owned.where((d) => d.role == DeviceRole.primary).length;
    if (primaryCount != 1) {
      _log.warning(
        'Skipping fanout during split-primary window ($primaryCount primaries)',
        tag: _tag,
      );
      return false;
    }

    return true;
  }
}

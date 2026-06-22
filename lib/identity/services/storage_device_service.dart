import '../../peer/models/paired_peer.dart' show PeerConnectionState;
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../models/device_role.dart';
import '../models/owned_device_record.dart';
import 'account_identity_service.dart';

/// Primary / Backup 存储设备查找（RPC、blob、pull 回退）。
class StorageDeviceService {
  StorageDeviceService._();

  /// Primary 优先，其次 Backup（按 device_id 稳定排序）。
  static Future<List<OwnedDeviceRecord>> devicesInFetchOrder() async {
    final all = await AccountIdentityService.instance.ownedDevices();
    final primary = all.where((d) => d.role == DeviceRole.primary).toList();
    final backups = all.where((d) => d.role == DeviceRole.backup).toList()
      ..sort((a, b) => a.deviceId.compareTo(b.deviceId));
    return [...primary, ...backups];
  }

  static Future<bool> isStorageDeviceId(String deviceId) async {
    final devices = await devicesInFetchOrder();
    return devices.any((d) => d.deviceId == deviceId);
  }

  static Future<String?> peerIdForDevice(String deviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == deviceId) return p.id;
    }
    return null;
  }

  /// 优先返回已连接的 Primary/Backup peer，否则回退到任意已配对 storage peer。
  static Future<String?> firstConnectedStoragePeerId() async {
    for (final device in await devicesInFetchOrder()) {
      final peerId = await peerIdForDevice(device.deviceId);
      if (peerId == null) continue;
      if (PeerConnectionManager.instance.getPeerState(peerId) ==
          PeerConnectionState.connected) {
        return peerId;
      }
    }
    return firstAvailableStoragePeerId();
  }

  /// 按 Primary → Backup 顺序返回第一个已配对的 peer id。
  static Future<String?> firstAvailableStoragePeerId() async {
    for (final device in await devicesInFetchOrder()) {
      final peerId = await peerIdForDevice(device.deviceId);
      if (peerId != null) return peerId;
    }
    return null;
  }
}

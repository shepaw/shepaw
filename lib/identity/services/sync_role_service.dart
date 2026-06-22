import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/logger_service.dart';
import '../models/owned_device_record.dart';
import 'account_identity_service.dart';

/// 设备角色广播（避免 AccountIdentityService ↔ SyncProtocolService 循环依赖）。
class SyncRoleService {
  SyncRoleService._();

  static const _tag = 'SyncRole';
  static final _log = LoggerService();

  /// 向已配对 peer 广播本机当前角色。
  static Future<void> announceLocalRole() async {
    try {
      await AccountIdentityService.instance.ensureInitialized();
      final local = await AccountIdentityService.instance.localDevice();
      if (local == null) return;

      final owned = await AccountIdentityService.instance.ownedDevices();
      for (final peer in owned) {
        if (peer.isLocal) continue;
        await _sendRoleAnnounce(peer.deviceId, local);
      }
    } catch (e) {
      _log.warning('Role announce failed: $e', tag: _tag);
    }
  }

  static Future<void> _sendRoleAnnounce(String peerDeviceId, OwnedDeviceRecord local) async {
    final paired = await _findPairedPeerId(peerDeviceId);
    if (paired == null) return;

    final elected = await AccountIdentityService.instance.userElectedPrimaryDeviceId();

    await PeerConnectionManager.instance.sendControl(paired, {
      'type': 'sync_role_announce',
      'device_id': local.deviceId,
      'device_name': local.deviceName,
      'role': local.role.wireValue,
      'user_id': local.userId,
      'pet_id': local.petId,
      'transport_fingerprint': local.fingerprint,
      'elected_primary_device_id': elected ?? '',
    });
  }

  static Future<String?> _findPairedPeerId(String deviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == deviceId) return p.id;
    }
    return null;
  }
}

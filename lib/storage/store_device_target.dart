import '../peer/models/paired_peer.dart';
import '../peer/services/peer_storage_service.dart';
import 'device_identity.dart';

/// `store://<space>/<device>/…` 里 device 段解析后的读写目标。
class StoreDeviceTarget {
  const StoreDeviceTarget({
    required this.deviceId,
    required this.isLocal,
    this.peerId,
    this.displayName,
  });

  /// URI / 协议里的 device id（Noise fingerprint，16 hex）。
  final String deviceId;

  /// 是否本机身份。
  final bool isLocal;

  /// 配对关系 id；本机或未配对时为 null。
  final String? peerId;

  /// 展示名（对端设备名）。
  final String? displayName;
}

/// 用 URI 中的 device id 匹配本机或已配对设备，再决定去哪读。
class StoreDeviceResolver {
  StoreDeviceResolver._();

  /// [deviceId] 先对本机 fingerprint，再对配对设备 fingerprint / device_id。
  static Future<StoreDeviceTarget> resolve(String deviceId) async {
    final self = await DeviceIdentity.deviceId();
    final key = deviceId.toLowerCase();
    if (deviceId == self || key == self.toLowerCase()) {
      return StoreDeviceTarget(deviceId: self, isLocal: true);
    }

    final peers = PeerStorageService();
    final peer = await peers.getPeerByFingerprint(key) ??
        await peers.getPeerByFingerprint(deviceId) ??
        await peers.getPeerByDeviceId(key) ??
        await peers.getPeerByDeviceId(deviceId);
    if (peer != null) {
      return _fromPeer(deviceId, peer);
    }

    return StoreDeviceTarget(deviceId: deviceId, isLocal: false);
  }

  static StoreDeviceTarget _fromPeer(String uriDeviceId, PairedPeer peer) {
    return StoreDeviceTarget(
      deviceId: uriDeviceId,
      isLocal: false,
      peerId: peer.id,
      displayName: peer.deviceName.isNotEmpty ? peer.deviceName : null,
    );
  }
}

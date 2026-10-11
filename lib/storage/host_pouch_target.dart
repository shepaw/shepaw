import '../peer/pairing_endpoints.dart';
import '../peer/services/peer_storage_service.dart';
import 'device_identity.dart';
import 'pouch_session.dart';

/// 储物袋页要打开的那一只袋子。
///
/// 手机和电脑登录的是同一只主机袋子，权限一样。电脑只是配对走本机回环，
/// 所以更快；不因此改用另一份本机目录。
class HostPouchTarget {
  const HostPouchTarget({
    required this.deviceId,
    this.peerId,
  });

  /// 要列的 device id（主机 Noise 指纹，或尚未登录时的本机指纹）。
  final String deviceId;

  /// 非空时经这条配对去读写 [deviceId]。
  final String? peerId;

  bool get isRemote => peerId != null && peerId!.isNotEmpty;

  static HostPouchTarget local(String deviceId) =>
      HostPouchTarget(deviceId: deviceId);

  /// 纯判断，方便单测。还没登录，或本机指纹就是主机，才读本机目录。
  static HostPouchTarget decide({
    required String selfId,
    required String? hostFingerprint,
    required String? hostPeerId,
  }) {
    final fingerprint = hostFingerprint?.trim() ?? '';
    final peerId = hostPeerId?.trim() ?? '';
    if (fingerprint.isEmpty ||
        peerId.isEmpty ||
        sameFingerprint(fingerprint, selfId)) {
      return HostPouchTarget.local(selfId);
    }
    return HostPouchTarget(deviceId: fingerprint, peerId: peerId);
  }

  static Future<HostPouchTarget> resolve() async {
    final self = await DeviceIdentity.deviceId();
    final session = await PouchSessionStore.readActive();
    final hostPeerId = session?.hostPeerId.trim() ?? '';
    if (hostPeerId.isEmpty) return HostPouchTarget.local(self);
    final host = await PeerStorageService().getPeerById(hostPeerId);
    return decide(
      selfId: self,
      hostFingerprint: host?.fingerprint,
      hostPeerId: hostPeerId,
    );
  }
}

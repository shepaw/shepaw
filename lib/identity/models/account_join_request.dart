import '../models/device_role.dart';

/// 待 Primary 审批的账号加入请求（来自 P2P control 通道）。
class AccountJoinPendingRequest {
  final String requestId;
  final String peerId;
  final String deviceId;
  final String deviceName;
  final String transportFingerprint;
  final String transportPublicKeyBase64;
  final DeviceRole preferredRole;
  final int requestedAtMs;

  const AccountJoinPendingRequest({
    required this.requestId,
    required this.peerId,
    required this.deviceId,
    required this.deviceName,
    required this.transportFingerprint,
    required this.transportPublicKeyBase64,
    required this.preferredRole,
    required this.requestedAtMs,
  });
}

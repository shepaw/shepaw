import 'dart:convert';

/// 由已有设备签发的「添加自有设备」邀请（QR / deep link）。
class DeviceTrustInvite {
  final int version;
  final String userId;
  final String petId;
  final String issuerDeviceId;
  final String issuerDeviceName;
  final String transportFingerprint;
  final String nonce;
  final int expiresAtMs;
  final String userPublicKeyBase64;
  final String signatureBase64;

  const DeviceTrustInvite({
    this.version = 1,
    required this.userId,
    required this.petId,
    required this.issuerDeviceId,
    required this.issuerDeviceName,
    required this.transportFingerprint,
    required this.nonce,
    required this.expiresAtMs,
    required this.userPublicKeyBase64,
    required this.signatureBase64,
  });

  bool get isExpired => DateTime.now().millisecondsSinceEpoch > expiresAtMs;

  /// 用户签名的 canonical payload（不含 signature 字段）。
  String get signedPayload =>
      'shepaw:device_trust:v$version:$userId:$petId:$issuerDeviceId:$transportFingerprint:$nonce:$expiresAtMs';

  Map<String, dynamic> toJson() => {
        'v': version,
        'type': 'shepaw_account_trust',
        'user_id': userId,
        'pet_id': petId,
        'issuer_device_id': issuerDeviceId,
        'issuer_device_name': issuerDeviceName,
        'transport_fingerprint': transportFingerprint,
        'nonce': nonce,
        'expires_at_ms': expiresAtMs,
        'user_pub': userPublicKeyBase64,
        'sig': signatureBase64,
      };

  factory DeviceTrustInvite.fromJson(Map<String, dynamic> json) {
    return DeviceTrustInvite(
      version: json['v'] as int? ?? 1,
      userId: json['user_id'] as String,
      petId: json['pet_id'] as String,
      issuerDeviceId: json['issuer_device_id'] as String,
      issuerDeviceName: json['issuer_device_name'] as String? ?? '',
      transportFingerprint: json['transport_fingerprint'] as String? ?? '',
      nonce: json['nonce'] as String,
      expiresAtMs: json['expires_at_ms'] as int,
      userPublicKeyBase64: json['user_pub'] as String,
      signatureBase64: json['sig'] as String,
    );
  }

  String toQrPayload() => jsonEncode(toJson());

  static DeviceTrustInvite? tryParseQr(String raw) {
    try {
      final trimmed = raw.trim();
      if (trimmed.startsWith('shepaw://account-trust?')) {
        final uri = Uri.parse(trimmed);
        final data = uri.queryParameters['data'];
        if (data == null) return null;
        return DeviceTrustInvite.fromJson(jsonDecode(Uri.decodeComponent(data)) as Map<String, dynamic>);
      }
      final obj = jsonDecode(trimmed);
      if (obj is! Map<String, dynamic>) return null;
      if (obj['type'] != 'shepaw_account_trust') return null;
      return DeviceTrustInvite.fromJson(obj);
    } catch (_) {
      return null;
    }
  }

  String toDeepLink() {
    final encoded = Uri.encodeComponent(toQrPayload());
    return 'shepaw://account-trust?data=$encoded';
  }
}

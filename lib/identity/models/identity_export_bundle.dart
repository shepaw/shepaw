import 'dart:convert';

import 'ownership_bond.dart';

/// 跨设备导入同一账号所需的密钥与认主状态包。
class IdentityExportBundle {
  final int version;
  final String userRecord;
  final String petRecord;
  final Map<String, dynamic>? bondMap;
  final int exportedAtMs;
  final String signatureBase64;

  const IdentityExportBundle({
    this.version = 1,
    required this.userRecord,
    required this.petRecord,
    this.bondMap,
    required this.exportedAtMs,
    required this.signatureBase64,
  });

  String get signedPayload =>
      'shepaw:identity_export:v$version:$exportedAtMs:${base64Url.encode(utf8.encode(userRecord))}:${base64Url.encode(utf8.encode(petRecord))}';

  OwnershipBond? get bond =>
      bondMap != null ? OwnershipBond.fromMap(bondMap!) : null;

  Map<String, dynamic> toJson() => {
        'v': version,
        'type': 'shepaw_identity_export',
        'user_record': userRecord,
        'pet_record': petRecord,
        if (bondMap != null) 'bond': bondMap,
        'exported_at_ms': exportedAtMs,
        'sig': signatureBase64,
      };

  factory IdentityExportBundle.fromJson(Map<String, dynamic> json) {
    return IdentityExportBundle(
      version: json['v'] as int? ?? 1,
      userRecord: json['user_record'] as String,
      petRecord: json['pet_record'] as String,
      bondMap: json['bond'] as Map<String, dynamic>?,
      exportedAtMs: json['exported_at_ms'] as int,
      signatureBase64: json['sig'] as String,
    );
  }

  String toPayloadJson() => jsonEncode(toJson());

  static IdentityExportBundle? tryParse(String raw) {
    try {
      final obj = jsonDecode(raw.trim()) as Map<String, dynamic>;
      if (obj['type'] != 'shepaw_identity_export') return null;
      return IdentityExportBundle.fromJson(obj);
    } catch (_) {
      return null;
    }
  }
}

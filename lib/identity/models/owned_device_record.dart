import 'dart:convert';
import 'dart:typed_data';

import 'device_role.dart';

/// 账号域内已信任的自有设备记录。
class OwnedDeviceRecord {
  final String id;
  final String deviceId;
  final String deviceName;
  final DeviceRole role;
  final Uint8List transportPublicKey;
  final String fingerprint;
  final String userId;
  final String petId;
  final bool isLocal;
  final int trustedAt;
  final int? lastSeenAt;

  const OwnedDeviceRecord({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.role,
    required this.transportPublicKey,
    required this.fingerprint,
    required this.userId,
    required this.petId,
    required this.isLocal,
    required this.trustedAt,
    this.lastSeenAt,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'device_id': deviceId,
        'device_name': deviceName,
        'role': role.wireValue,
        'transport_public_key': base64.encode(transportPublicKey),
        'fingerprint': fingerprint,
        'user_id': userId,
        'pet_id': petId,
        'is_local': isLocal ? 1 : 0,
        'trusted_at': trustedAt,
        'last_seen_at': lastSeenAt,
      };

  factory OwnedDeviceRecord.fromMap(Map<String, dynamic> map) {
    final keyRaw = map['transport_public_key'] as String? ?? '';
    return OwnedDeviceRecord(
      id: map['id'] as String,
      deviceId: map['device_id'] as String,
      deviceName: map['device_name'] as String? ?? '',
      role: DeviceRole.fromWire(map['role'] as String?),
      transportPublicKey: Uint8List.fromList(base64.decode(keyRaw)),
      fingerprint: map['fingerprint'] as String? ?? '',
      userId: map['user_id'] as String,
      petId: map['pet_id'] as String,
      isLocal: (map['is_local'] as int? ?? 0) == 1,
      trustedAt: map['trusted_at'] as int,
      lastSeenAt: map['last_seen_at'] as int?,
    );
  }

  OwnedDeviceRecord copyWith({
    String? deviceName,
    DeviceRole? role,
    int? lastSeenAt,
  }) {
    return OwnedDeviceRecord(
      id: id,
      deviceId: deviceId,
      deviceName: deviceName ?? this.deviceName,
      role: role ?? this.role,
      transportPublicKey: transportPublicKey,
      fingerprint: fingerprint,
      userId: userId,
      petId: petId,
      isLocal: isLocal,
      trustedAt: trustedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}

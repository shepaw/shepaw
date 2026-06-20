import 'dart:convert';
import 'dart:typed_data';

/// User ↔ SpiritPet 认主绑定记录。
class OwnershipBond {
  final String petId;
  final String userId;
  final String ownerFingerprint;
  final int bondedAt;
  final Uint8List bondSignature;

  const OwnershipBond({
    required this.petId,
    required this.userId,
    required this.ownerFingerprint,
    required this.bondedAt,
    required this.bondSignature,
  });

  Map<String, dynamic> toMap() => {
        'pet_id': petId,
        'user_id': userId,
        'owner_fingerprint': ownerFingerprint,
        'bonded_at': bondedAt,
        'bond_signature': base64.encode(bondSignature),
      };

  factory OwnershipBond.fromMap(Map<String, dynamic> map) {
    return OwnershipBond(
      petId: map['pet_id'] as String,
      userId: map['user_id'] as String,
      ownerFingerprint: map['owner_fingerprint'] as String? ?? '',
      bondedAt: map['bonded_at'] as int,
      bondSignature: Uint8List.fromList(base64.decode(map['bond_signature'] as String)),
    );
  }
}

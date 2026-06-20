import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/crypto/ed25519_identity.dart';
import 'package:shepaw/identity/models/device_trust_invite.dart';
import 'package:shepaw/identity/services/device_trust_service.dart';

void main() {
  group('DeviceTrustInvite', () {
    test('verify valid signature', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final priv = await keyPair.extractPrivateKeyBytes();
      final pub = await keyPair.extractPublicKey();
      final user = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(pub.bytes),
        privateKey: Uint8List.fromList(priv),
      );

      const expires = 9999999999999;
      final unsigned = DeviceTrustInvite(
        userId: user.fingerprintHex,
        petId: 'pet1234567890abcd',
        issuerDeviceId: 'device-1',
        issuerDeviceName: 'Mac',
        transportFingerprint: 'aabbccdd',
        nonce: 'abc123',
        expiresAtMs: expires,
        userPublicKeyBase64: user.publicKeyBase64,
        signatureBase64: '',
      );
      final sig = await user.signUtf8(unsigned.signedPayload);
      final invite = DeviceTrustInvite(
        userId: unsigned.userId,
        petId: unsigned.petId,
        issuerDeviceId: unsigned.issuerDeviceId,
        issuerDeviceName: unsigned.issuerDeviceName,
        transportFingerprint: unsigned.transportFingerprint,
        nonce: unsigned.nonce,
        expiresAtMs: unsigned.expiresAtMs,
        userPublicKeyBase64: unsigned.userPublicKeyBase64,
        signatureBase64: base64.encode(sig),
      );

      expect(await DeviceTrustService.instance.verifyInvite(invite), isTrue);
    });

    test('tryParseQr roundtrip', () {
      final invite = DeviceTrustInvite(
        userId: 'user1',
        petId: 'pet1',
        issuerDeviceId: 'd1',
        issuerDeviceName: 'Mac',
        transportFingerprint: 'fp',
        nonce: 'n',
        expiresAtMs: 9999999999999,
        userPublicKeyBase64: 'AAAA',
        signatureBase64: 'BBBB',
      );
      final parsed = DeviceTrustInvite.tryParseQr(invite.toQrPayload());
      expect(parsed?.userId, 'user1');
      expect(parsed?.issuerDeviceId, 'd1');
    });
  });
}

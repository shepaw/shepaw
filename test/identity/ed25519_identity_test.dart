import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/crypto/ed25519_identity.dart';
import 'package:shepaw/identity/services/ownership_service.dart';

void main() {
  group('Ed25519Identity', () {
    test('fingerprint is 16 hex chars', () {
      final id = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i)),
        privateKey: Uint8List(32),
      );
      expect(id.fingerprintHex.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id.fingerprintHex), isTrue);
    });

    test('encode/decode roundtrip', () {
      final id = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(List.generate(32, (i) => 255 - i)),
        privateKey: Uint8List.fromList(List.generate(32, (i) => i * 3 % 256)),
        createdAtMs: 1700000000000,
      );
      final parsed = Ed25519Identity.parseRecord(id.encodeRecord());
      expect(parsed.publicKey, id.publicKey);
      expect(parsed.privateKey, id.privateKey);
      expect(parsed.createdAtMs, 1700000000000);
    });

    test('sign and verify', () async {
      final algorithm = Ed25519();
      final keyPair = await algorithm.newKeyPair();
      final priv = await keyPair.extractPrivateKeyBytes();
      final pub = await keyPair.extractPublicKey();

      final id = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(pub.bytes),
        privateKey: Uint8List.fromList(priv),
      );

      const message = 'shepaw:test';
      final sig = await id.signUtf8(message);
      expect(
        await Ed25519Identity.verifyUtf8(
          message: message,
          signature: sig,
          publicKey: id.publicKey,
        ),
        isTrue,
      );
    });
  });

  group('OwnershipService.bondPayload', () {
    test('payload format is stable', () {
      final p = OwnershipService.bondPayload(
        userId: 'abc123',
        petId: 'def456',
        timestampMs: 1000,
      );
      expect(p, 'shepaw:ownership:v1:abc123:def456:1000');
    });
  });
}

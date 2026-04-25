import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise_identity.dart';

void main() {
  group('NoiseIdentity.fromRawBytes', () {
    test('accepts 32-byte keys', () {
      final id = NoiseIdentity.fromRawBytes(
        publicKey: Uint8List(32),
        privateKey: Uint8List(32),
        createdAtMs: 1700000000000,
      );
      expect(id.publicKey.length, 32);
      expect(id.privateKey.length, 32);
      expect(id.createdAtMs, 1700000000000);
    });

    test('rejects wrong-length public key', () {
      expect(
        () => NoiseIdentity.fromRawBytes(
          publicKey: Uint8List(31),
          privateKey: Uint8List(32),
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-length private key', () {
      expect(
        () => NoiseIdentity.fromRawBytes(
          publicKey: Uint8List(32),
          privateKey: Uint8List(16),
        ),
        throwsArgumentError,
      );
    });
  });

  group('NoiseIdentity.fingerprintHex', () {
    test('matches the agent SDK derivedFingerprint for the all-zero pub', () {
      // sha256(bytes[0..31] == 0x00..0x00) first 8 bytes, lowercase hex.
      // Precomputed: SHA-256 of 32 zero bytes is
      // 66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
      final id = NoiseIdentity.fromRawBytes(
        publicKey: Uint8List(32),
        privateKey: Uint8List(32),
      );
      expect(id.fingerprintHex, '66687aadf862bd77');
    });

    test('differs for different public keys', () {
      final a = NoiseIdentity.fromRawBytes(
        publicKey: Uint8List(32),
        privateKey: Uint8List(32),
      );
      final bPub = Uint8List(32);
      bPub[0] = 1;
      final b = NoiseIdentity.fromRawBytes(
        publicKey: bPub,
        privateKey: Uint8List(32),
      );
      expect(a.fingerprintHex, isNot(b.fingerprintHex));
    });

    test('always 16 hex chars', () {
      for (var seed = 0; seed < 5; seed++) {
        final pub = Uint8List(32);
        for (var i = 0; i < 32; i++) {
          pub[i] = (seed * 31 + i) & 0xff;
        }
        final id = NoiseIdentity.fromRawBytes(
          publicKey: pub,
          privateKey: Uint8List(32),
        );
        expect(id.fingerprintHex.length, 16);
        expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(id.fingerprintHex), isTrue);
      }
    });
  });

  group('NoiseIdentity codec', () {
    test('encode → parse roundtrips with timestamp', () {
      final pub = Uint8List(32);
      final priv = Uint8List(32);
      for (var i = 0; i < 32; i++) {
        pub[i] = i;
        priv[i] = 255 - i;
      }
      final original = NoiseIdentity.fromRawBytes(
        publicKey: pub,
        privateKey: priv,
        createdAtMs: 1700000000000,
      );
      final encoded = original.encodeRecord();
      expect(encoded.startsWith('v1.'), isTrue);
      expect(encoded.split('.').length, 4);

      final parsed = NoiseIdentity.parseRecord(encoded);
      expect(parsed.publicKey, equals(pub));
      expect(parsed.privateKey, equals(priv));
      expect(parsed.createdAtMs, 1700000000000);
    });

    test('parses legacy 3-part record (no timestamp)', () {
      // This is the format we would've used if we shipped before adding the
      // timestamp field; keeping parse support so an early v1 entry doesn't
      // fail to load after an upgrade.
      final pub = Uint8List(32);
      final priv = Uint8List(32);
      const b64Pub =
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='; // 32 zero bytes
      const legacy = 'v1.$b64Pub.$b64Pub';
      final parsed = NoiseIdentity.parseRecord(legacy);
      expect(parsed.publicKey, equals(pub));
      expect(parsed.privateKey, equals(priv));
      expect(parsed.createdAtMs, isNull);
    });

    test('rejects unknown version prefix', () {
      expect(
        () => NoiseIdentity.parseRecord('v2.abc.def.123'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects wrong part count', () {
      expect(
        () => NoiseIdentity.parseRecord('v1.abc'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => NoiseIdentity.parseRecord('v1.a.b.c.d'),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects wrong-length keys', () {
      // base64 of 16 zero bytes = "AAAAAAAAAAAAAAAAAAAAAA=="
      const bad = 'v1.AAAAAAAAAAAAAAAAAAAAAA==.AAAAAAAAAAAAAAAAAAAAAA==.0';
      expect(
        () => NoiseIdentity.parseRecord(bad),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid timestamp', () {
      const b64Pub = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
      expect(
        () => NoiseIdentity.parseRecord('v1.$b64Pub.$b64Pub.not-a-number'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('X25519 generation (real keypair)', () {
    test('fresh keypair has valid lengths and derives to agreed-upon shared secret', () async {
      // This test exercises the same primitive flow NoiseIdentity._generate uses,
      // but explicitly — we can't call the private _generate directly from here,
      // and we don't want to touch SecureKeyManager in a unit test.
      final algo = X25519();
      final alicePair = await algo.newKeyPair();
      final bobPair = await algo.newKeyPair();

      final alicePriv = await alicePair.extractPrivateKeyBytes();
      final alicePub = await alicePair.extractPublicKey();
      expect(alicePriv.length, 32);
      expect(alicePub.bytes.length, 32);

      // End-to-end sanity: ECDH yields the same 32-byte shared secret both ways.
      final sharedA = await algo.sharedSecretKey(
        keyPair: alicePair,
        remotePublicKey: await bobPair.extractPublicKey(),
      );
      final sharedB = await algo.sharedSecretKey(
        keyPair: bobPair,
        remotePublicKey: alicePub,
      );
      final bytesA = await sharedA.extractBytes();
      final bytesB = await sharedB.extractBytes();
      expect(bytesA.length, 32);
      expect(bytesA, equals(bytesB));
    });

    test('toCryptographyKeyPair returns a usable keypair wrapper', () async {
      final algo = X25519();
      final fresh = await algo.newKeyPair();
      final priv = Uint8List.fromList(await fresh.extractPrivateKeyBytes());
      final pub = Uint8List.fromList((await fresh.extractPublicKey()).bytes);

      final id = NoiseIdentity.fromRawBytes(publicKey: pub, privateKey: priv);
      final wrapper = id.toCryptographyKeyPair();

      // The wrapper should round-trip through extract* the same bytes.
      final wrapperPriv = await wrapper.extractPrivateKeyBytes();
      final wrapperPub = await wrapper.extractPublicKey();
      expect(wrapperPriv, equals(priv));
      expect(wrapperPub.bytes, equals(pub));

      // And it should be able to ECDH with a fresh peer.
      final peer = await algo.newKeyPair();
      final peerPub = await peer.extractPublicKey();
      final shared = await algo.sharedSecretKey(
        keyPair: wrapper,
        remotePublicKey: peerPub,
      );
      expect((await shared.extractBytes()).length, 32);
    });
  });
}

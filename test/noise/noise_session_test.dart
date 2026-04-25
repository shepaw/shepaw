import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise/noise_primitives.dart';
import 'package:shepaw/services/noise/noise_session.dart';

void main() {
  // Reusable fixtures.
  late ({Uint8List privateKey, Uint8List publicKey}) alice;
  late ({Uint8List privateKey, Uint8List publicKey}) bob;

  setUp(() async {
    alice = await noiseGenerateKeyPair();
    bob = await noiseGenerateKeyPair();
  });

  /// Drive a full initiator+responder handshake. Returns both sessions
  /// ready for transport.
  Future<({NoiseSession init, NoiseSession resp})> driveHandshake() async {
    final init = await NoiseSession.initiator(
      staticPublicKey: alice.publicKey,
      staticPrivateKey: alice.privateKey,
      pinnedPeerStaticPublicKey: bob.publicKey,
    );
    final resp = await NoiseSession.responder(
      staticPublicKey: bob.publicKey,
      staticPrivateKey: bob.privateKey,
    );

    final msg1 = await init.writeHandshake1(<int>[]);
    await resp.readHandshake1(msg1);
    final msg2 = await resp.writeHandshake2(<int>[]);
    await init.readHandshake2(msg2);

    return (init: init, resp: resp);
  }

  group('NoiseSession handshake lifecycle', () {
    test('initiator and responder both become ready after a clean exchange', () async {
      final s = await driveHandshake();
      expect(s.init.ready, isTrue);
      expect(s.resp.ready, isTrue);
    });

    test('msg1 payload passes through unchanged', () async {
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: bob.publicKey,
      );
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      final msg1 = await init.writeHandshake1(ascii.encode('{"agentId":"claim"}'));
      final r = await resp.readHandshake1(msg1);
      expect(ascii.decode(r.msg1Payload), '{"agentId":"claim"}');
      // Responder now knows the initiator's static pub key.
      expect(r.peerStaticPublicKey, equals(alice.publicKey));
    });

    test('msg2 payload passes through unchanged', () async {
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: bob.publicKey,
      );
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      await resp.readHandshake1(await init.writeHandshake1(<int>[]));
      final msg2 = await resp.writeHandshake2(ascii.encode('{"agentId":"real"}'));
      final r = await init.readHandshake2(msg2);
      expect(ascii.decode(r.msg2Payload), '{"agentId":"real"}');
      expect(r.peerStaticPublicKey, equals(bob.publicKey));
    });
  });

  group('NoiseSession transport', () {
    test('initiator → responder roundtrip', () async {
      final s = await driveHandshake();
      final ct = await s.init.encrypt(ascii.encode('hello from app'));
      final pt = await s.resp.decrypt(ct);
      expect(ascii.decode(pt), 'hello from app');
    });

    test('responder → initiator roundtrip', () async {
      final s = await driveHandshake();
      final ct = await s.resp.encrypt(ascii.encode('hello from agent'));
      final pt = await s.init.decrypt(ct);
      expect(ascii.decode(pt), 'hello from agent');
    });

    test('nonces advance: identical plaintexts produce distinct ciphertexts', () async {
      final s = await driveHandshake();
      final a = await s.init.encrypt(ascii.encode('same'));
      final b = await s.init.encrypt(ascii.encode('same'));
      expect(a, isNot(equals(b)));
    });

    test('50 consecutive messages each decrypt to their own plaintext', () async {
      final s = await driveHandshake();
      for (var i = 0; i < 50; i++) {
        final ct = await s.init.encrypt(ascii.encode('msg $i'));
        final pt = await s.resp.decrypt(ct);
        expect(ascii.decode(pt), 'msg $i');
      }
    });

    test('tampered ciphertext throws NoiseTransportError', () async {
      final s = await driveHandshake();
      final ct = await s.init.encrypt(ascii.encode('valid'));
      ct[5] ^= 0xff;
      expect(
        () => s.resp.decrypt(ct),
        throwsA(isA<NoiseTransportError>()),
      );
    });

    test('a decrypt failure closes the session', () async {
      final s = await driveHandshake();
      final ct = await s.init.encrypt(ascii.encode('valid'));
      ct[5] ^= 0xff;
      try {
        await s.resp.decrypt(ct);
      } catch (_) {
        // expected
      }
      expect(
        () => s.resp.encrypt(ascii.encode('still alive?')),
        throwsA(isA<NoiseTransportError>()),
      );
    });
  });

  group('NoiseSession negative cases', () {
    test('out-of-order initiator calls', () async {
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: bob.publicKey,
      );
      expect(
        () => init.readHandshake2(<int>[]),
        throwsA(isA<NoiseTransportError>()),
      );
    });

    test('out-of-order responder calls', () async {
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      expect(
        () => resp.writeHandshake2(<int>[]),
        throwsA(isA<NoiseTransportError>()),
      );
    });

    test('fingerprint mismatch: initiator pins the wrong pubkey', () async {
      // Initiator pins Eve's key, but real responder is Bob.
      final eve = await noiseGenerateKeyPair();
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: eve.publicKey,
      );
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      // readHandshake1 will fail AEAD during the `s` step — the `es` DH
      // doesn't match.
      await expectLater(
        resp.readHandshake1(await init.writeHandshake1(<int>[])),
        throwsA(isA<Exception>()),
      );
    });

    test('close() is idempotent and disables further use', () async {
      final s = await driveHandshake();
      s.init.close();
      s.init.close(); // no throw
      expect(
        () => s.init.encrypt(ascii.encode('after close')),
        throwsA(isA<NoiseTransportError>()),
      );
    });
  });

  group('NoiseSession peerStaticPublicKey visibility', () {
    test('initiator knows peer from construction', () async {
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: bob.publicKey,
      );
      expect(init.peerStaticPublicKey, equals(bob.publicKey));
    });

    test('responder does not know peer before msg 1', () async {
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      expect(
        () => resp.peerStaticPublicKey,
        throwsA(isA<NoiseTransportError>()),
      );
    });

    test('responder knows peer after msg 1', () async {
      final init = await NoiseSession.initiator(
        staticPublicKey: alice.publicKey,
        staticPrivateKey: alice.privateKey,
        pinnedPeerStaticPublicKey: bob.publicKey,
      );
      final resp = await NoiseSession.responder(
        staticPublicKey: bob.publicKey,
        staticPrivateKey: bob.privateKey,
      );
      await resp.readHandshake1(await init.writeHandshake1(<int>[]));
      expect(resp.peerStaticPublicKey, equals(alice.publicKey));
    });
  });
}

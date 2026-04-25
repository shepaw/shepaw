import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise/noise_handshake_state.dart';
import 'package:shepaw/services/noise/noise_primitives.dart';

void main() {
  group('HandshakeState initialize', () {
    test('initiator requires remoteStaticPublicKey', () async {
      final kp = await noiseGenerateKeyPair();
      expect(
        () => HandshakeState.initialize(
          initiator: true,
          staticPublicKey: kp.publicKey,
          staticPrivateKey: kp.privateKey,
        ),
        throwsArgumentError,
      );
    });

    test('responder must not pre-set remoteStaticPublicKey', () async {
      final kp = await noiseGenerateKeyPair();
      final other = await noiseGenerateKeyPair();
      expect(
        () => HandshakeState.initialize(
          initiator: false,
          staticPublicKey: kp.publicKey,
          staticPrivateKey: kp.privateKey,
          remoteStaticPublicKey: other.publicKey,
        ),
        throwsArgumentError,
      );
    });

    test('rejects wrong-length keys', () async {
      final shortKey = Uint8List(31);
      final ok = Uint8List(32);
      expect(
        () => HandshakeState.initialize(
          initiator: false,
          staticPublicKey: shortKey,
          staticPrivateKey: ok,
        ),
        throwsArgumentError,
      );
      expect(
        () => HandshakeState.initialize(
          initiator: false,
          staticPublicKey: ok,
          staticPrivateKey: shortKey,
        ),
        throwsArgumentError,
      );
    });
  });

  group('IK handshake full roundtrip (Dart ↔ Dart)', () {
    test('empty payloads — completes and yields matching split keys', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);

      final w1 = await init.writeMessage(<int>[]);
      expect(w1.split, isNull);

      final r1 = await resp.readMessage(w1.message);
      expect(r1.split, isNull);
      expect(r1.payload.length, 0);
      // Responder now knows initiator's static public key.
      expect(resp.remoteStaticPublicKey, isNotNull);
      expect(resp.remoteStaticPublicKey, equals(init.sPub));

      final w2 = await resp.writeMessage(<int>[]);
      expect(w2.split, isNotNull);

      final r2 = await init.readMessage(w2.message);
      expect(r2.split, isNotNull);
      expect(r2.payload.length, 0);

      // Both sides finished.
      expect(init.finished, isTrue);
      expect(resp.finished, isTrue);

      // Split keys match: c1 equal, c2 equal.
      expect(r2.split!.c1Key, equals(w2.split!.c1Key));
      expect(r2.split!.c2Key, equals(w2.split!.c2Key));
    });

    test('msg1 payload traverses encrypted', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);

      final payload = ascii.encode('{"agentId":"claim"}');
      final w1 = await init.writeMessage(payload);
      final r1 = await resp.readMessage(w1.message);
      expect(ascii.decode(r1.payload), '{"agentId":"claim"}');
    });

    test('msg2 payload traverses encrypted', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);

      await resp.readMessage((await init.writeMessage(<int>[])).message);

      final m2Payload = ascii.encode('{"agentId":"real"}');
      final w2 = await resp.writeMessage(m2Payload);
      final r2 = await init.readMessage(w2.message);
      expect(ascii.decode(r2.payload), '{"agentId":"real"}');
    });

    test('produces different ciphertexts across two independent handshakes', () async {
      final init1 = await _setupInitiator();
      final init2 = await _setupInitiator();
      final m1a = (await init1.writeMessage(ascii.encode('same'))).message;
      final m1b = (await init2.writeMessage(ascii.encode('same'))).message;
      // Ephemerals differ, so msg 1 bytes differ.
      expect(m1a, isNot(equals(m1b)));
    });

    test('msg1 size is exactly 32 (e) + 48 (encrypted s + tag) + 16 (empty payload + tag) = 96', () async {
      final init = await _setupInitiator();
      final w1 = await init.writeMessage(<int>[]);
      expect(w1.message.length, 96);
    });

    test('msg2 size is exactly 32 (e) + 16 (empty payload + tag) = 48', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);
      await resp.readMessage((await init.writeMessage(<int>[])).message);
      final w2 = await resp.writeMessage(<int>[]);
      expect(w2.message.length, 48);
    });
  });

  group('IK handshake negative cases', () {
    test('initiator with wrong pinned responder static → responder decrypt fails', () async {
      // Initiator pins a bogus responder pubkey; real responder has a different
      // static private. The `es` DH will not match, so `s` decryption in msg 1
      // fails with an AEAD tag mismatch (surfaced as NoiseAeadFailure wrapped).
      final iKp = await noiseGenerateKeyPair();
      final bogus = await noiseGenerateKeyPair();
      final realRespKp = await noiseGenerateKeyPair();

      final init = await HandshakeState.initialize(
        initiator: true,
        staticPublicKey: iKp.publicKey,
        staticPrivateKey: iKp.privateKey,
        remoteStaticPublicKey: bogus.publicKey, // wrong
      );
      final resp = await HandshakeState.initialize(
        initiator: false,
        staticPublicKey: realRespKp.publicKey,
        staticPrivateKey: realRespKp.privateKey,
      );

      final w1 = await init.writeMessage(<int>[]);
      await expectLater(resp.readMessage(w1.message), throwsA(isA<Exception>()));
    });

    test('prologue mismatch → responder decrypt fails', () async {
      final iKp = await noiseGenerateKeyPair();
      final rKp = await noiseGenerateKeyPair();
      final init = await HandshakeState.initialize(
        initiator: true,
        staticPublicKey: iKp.publicKey,
        staticPrivateKey: iKp.privateKey,
        remoteStaticPublicKey: rKp.publicKey,
        prologue: ascii.encode('wrong'),
      );
      final resp = await HandshakeState.initialize(
        initiator: false,
        staticPublicKey: rKp.publicKey,
        staticPrivateKey: rKp.privateKey,
        // default prologue
      );
      final w1 = await init.writeMessage(<int>[]);
      await expectLater(resp.readMessage(w1.message), throwsA(isA<Exception>()));
    });

    test('truncated msg1 → NoiseHandshakeError', () async {
      final iKp = await noiseGenerateKeyPair();
      final rKp = await noiseGenerateKeyPair();
      final init = await HandshakeState.initialize(
        initiator: true,
        staticPublicKey: iKp.publicKey,
        staticPrivateKey: iKp.privateKey,
        remoteStaticPublicKey: rKp.publicKey,
      );
      final resp = await HandshakeState.initialize(
        initiator: false,
        staticPublicKey: rKp.publicKey,
        staticPrivateKey: rKp.privateKey,
      );
      final w1 = await init.writeMessage(<int>[]);
      // Cut to 32 bytes — below the minimum 80-byte length.
      final truncated = w1.message.sublist(0, 32);
      expect(
        () => resp.readMessage(truncated),
        throwsA(isA<NoiseHandshakeError>()),
      );
    });

    test('truncated msg2 → NoiseHandshakeError', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);
      await resp.readMessage((await init.writeMessage(<int>[])).message);
      final w2 = await resp.writeMessage(<int>[]);
      final truncated = w2.message.sublist(0, 16);
      expect(
        () => init.readMessage(truncated),
        throwsA(isA<NoiseHandshakeError>()),
      );
    });

    test('double-write after finish → NoiseHandshakeError', () async {
      final init = await _setupInitiator();
      final resp = await _setupResponder(initiatorRemoteStaticFrom: init);
      final w1 = await init.writeMessage(<int>[]);
      await resp.readMessage(w1.message);
      await resp.writeMessage(<int>[]);
      expect(
        () => resp.writeMessage(<int>[]),
        throwsA(isA<NoiseHandshakeError>()),
      );
    });

    test('crossed roles: responder cannot writeMessage first', () async {
      final resp = await _setupResponder();
      // Responder calling writeMessage without having read msg1 first
      // is a phase violation.
      expect(
        () => resp.writeMessage(<int>[]),
        throwsA(isA<NoiseHandshakeError>()),
      );
    });
  });

  group('HandshakeState constants', () {
    test('noiseProtocolName is the canonical string', () {
      expect(noiseProtocolName, 'Noise_IK_25519_ChaChaPoly_BLAKE2b');
    });

    test('noisePrologueDefault encodes "shepaw-acp/2.1" (v2.1 binding)', () {
      expect(ascii.decode(noisePrologueDefault), 'shepaw-acp/2.1');
    });
  });
}

// ── Fixtures ──────────────────────────────────────────────────────────────

// Stable responder keypair for tests that need matching initiator pinning.
// Regenerated per test case via the factories below.
Future<HandshakeState> _setupInitiator() async {
  final respKp = await noiseGenerateKeyPair();
  final initKp = await noiseGenerateKeyPair();
  final init = await HandshakeState.initialize(
    initiator: true,
    staticPublicKey: initKp.publicKey,
    staticPrivateKey: initKp.privateKey,
    remoteStaticPublicKey: respKp.publicKey,
  );
  // Attach the responder's keypair so the matching _setupResponder can use it.
  _latestResp = respKp;
  return init;
}

Future<HandshakeState> _setupResponder({HandshakeState? initiatorRemoteStaticFrom}) async {
  // Use the keypair stashed by the most recent `_setupInitiator`, so the
  // responder's sPriv actually matches the pinned public the initiator used.
  final respKp = _latestResp ?? await noiseGenerateKeyPair();
  _latestResp = null;
  return HandshakeState.initialize(
    initiator: false,
    staticPublicKey: respKp.publicKey,
    staticPrivateKey: respKp.privateKey,
  );
}

({Uint8List privateKey, Uint8List publicKey})? _latestResp;

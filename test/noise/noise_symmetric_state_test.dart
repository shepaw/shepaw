import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise/noise_primitives.dart';
import 'package:shepaw/services/noise/noise_symmetric_state.dart';

void main() {
  group('SymmetricState.initialize', () {
    test('short protocol name is zero-padded to HASHLEN', () async {
      final name = ascii.encode('Noise_IK_25519_ChaChaPoly_BLAKE2b');
      expect(name.length <= noiseHashLen, isTrue);
      final ss = await SymmetricState.initialize(name);
      expect(ss.h.length, noiseHashLen);
      // First 33 bytes should match, rest are zero.
      for (var i = 0; i < name.length; i++) {
        expect(ss.h[i], name[i]);
      }
      for (var i = name.length; i < noiseHashLen; i++) {
        expect(ss.h[i], 0);
      }
      // Chaining key starts equal to handshake hash.
      expect(ss.ck, equals(ss.h));
      expect(ss.hasKey, isFalse);
      expect(ss.n, 0);
    });

    test('long protocol name is hashed', () async {
      final longName = Uint8List(200);
      for (var i = 0; i < 200; i++) {
        longName[i] = i & 0xff;
      }
      final ss = await SymmetricState.initialize(longName);
      expect(ss.h.length, noiseHashLen);
      final directHash = await noiseHash(longName);
      expect(ss.h, equals(directHash));
      expect(ss.ck, equals(directHash));
    });
  });

  group('SymmetricState.mixHash', () {
    test('advances h deterministically', () async {
      final a = await SymmetricState.initialize(ascii.encode('test'));
      final b = await SymmetricState.initialize(ascii.encode('test'));
      await a.mixHash(<int>[1, 2, 3]);
      await b.mixHash(<int>[1, 2, 3]);
      expect(a.h, equals(b.h));
    });

    test('different data advances h differently', () async {
      final a = await SymmetricState.initialize(ascii.encode('test'));
      final b = await SymmetricState.initialize(ascii.encode('test'));
      await a.mixHash(<int>[1]);
      await b.mixHash(<int>[2]);
      expect(a.h, isNot(equals(b.h)));
    });
  });

  group('SymmetricState.mixKey', () {
    test('sets k and resets n', () async {
      final ss = await SymmetricState.initialize(ascii.encode('test'));
      expect(ss.hasKey, isFalse);
      ss.n = 99;
      await ss.mixKey(<int>[1, 2, 3, 4, 5]);
      expect(ss.hasKey, isTrue);
      expect(ss.k!.length, noiseKeyLen);
      expect(ss.n, 0);
    });

    test('advances the chaining key', () async {
      final ss = await SymmetricState.initialize(ascii.encode('test'));
      final ckBefore = Uint8List.fromList(ss.ck);
      await ss.mixKey(<int>[9, 9, 9]);
      expect(ss.ck, isNot(equals(ckBefore)));
    });

    test('deterministic', () async {
      final a = await SymmetricState.initialize(ascii.encode('test'));
      final b = await SymmetricState.initialize(ascii.encode('test'));
      await a.mixKey(<int>[1, 2, 3]);
      await b.mixKey(<int>[1, 2, 3]);
      expect(a.ck, equals(b.ck));
      expect(a.k, equals(b.k));
    });
  });

  group('SymmetricState.encryptAndHash / decryptAndHash', () {
    test('unkeyed branch just mixes hash with plaintext == ciphertext', () async {
      final enc = await SymmetricState.initialize(ascii.encode('test'));
      final dec = await SymmetricState.initialize(ascii.encode('test'));
      expect(enc.hasKey, isFalse);

      final ct = await enc.encryptAndHash(ascii.encode('hello'));
      expect(ascii.decode(ct), 'hello');

      final pt = await dec.decryptAndHash(ct);
      expect(ascii.decode(pt), 'hello');

      // Hashes stayed in sync.
      expect(enc.h, equals(dec.h));
    });

    test('keyed branch: encrypt then decrypt symmetrically', () async {
      final enc = await SymmetricState.initialize(ascii.encode('test'));
      final dec = await SymmetricState.initialize(ascii.encode('test'));
      await enc.mixKey(<int>[1, 2, 3]);
      await dec.mixKey(<int>[1, 2, 3]);
      expect(enc.hasKey, isTrue);

      final ct = await enc.encryptAndHash(ascii.encode('secret'));
      expect(ct.length, 'secret'.length + 16);

      final pt = await dec.decryptAndHash(ct);
      expect(ascii.decode(pt), 'secret');
      // Nonces advanced in sync.
      expect(enc.n, 1);
      expect(dec.n, 1);
      // Hashes stayed in sync.
      expect(enc.h, equals(dec.h));
    });

    test('decryptAndHash with wrong hash (h) fails', () async {
      final enc = await SymmetricState.initialize(ascii.encode('testA'));
      final dec = await SymmetricState.initialize(ascii.encode('testB'));
      await enc.mixKey(<int>[1, 2, 3]);
      await dec.mixKey(<int>[1, 2, 3]);

      final ct = await enc.encryptAndHash(ascii.encode('x'));
      expect(
        () => dec.decryptAndHash(ct),
        throwsA(isA<NoiseAeadFailure>()),
      );
    });

    test('consecutive encrypt calls use counter 0 then 1', () async {
      final enc = await SymmetricState.initialize(ascii.encode('test'));
      final dec = await SymmetricState.initialize(ascii.encode('test'));
      await enc.mixKey(<int>[42]);
      await dec.mixKey(<int>[42]);

      final ct1 = await enc.encryptAndHash(ascii.encode('one'));
      final ct2 = await enc.encryptAndHash(ascii.encode('two'));
      // Same plaintext won't repeat — already verified above — but more
      // importantly the decrypt side must consume in order.
      final pt1 = await dec.decryptAndHash(ct1);
      final pt2 = await dec.decryptAndHash(ct2);
      expect(ascii.decode(pt1), 'one');
      expect(ascii.decode(pt2), 'two');
      expect(enc.n, 2);
      expect(dec.n, 2);
    });

    test('empty plaintext — keyed — yields a 16-byte MAC-only ciphertext', () async {
      final enc = await SymmetricState.initialize(ascii.encode('test'));
      final dec = await SymmetricState.initialize(ascii.encode('test'));
      await enc.mixKey(<int>[1]);
      await dec.mixKey(<int>[1]);
      final ct = await enc.encryptAndHash(<int>[]);
      expect(ct.length, 16);
      final pt = await dec.decryptAndHash(ct);
      expect(pt.length, 0);
    });
  });

  group('SymmetricState.split', () {
    test('gives two distinct 32-byte keys', () async {
      final ss = await SymmetricState.initialize(ascii.encode('test'));
      await ss.mixKey(<int>[1, 2, 3, 4]);
      final s = await ss.split();
      expect(s.c1Key.length, noiseKeyLen);
      expect(s.c2Key.length, noiseKeyLen);
      expect(s.c1Key, isNot(equals(s.c2Key)));
    });

    test('both parties end up with matching c1 and c2 if handshakes match', () async {
      // Simulate both parties doing identical operations.
      final a = await SymmetricState.initialize(ascii.encode('Noise_IK_foo'));
      final b = await SymmetricState.initialize(ascii.encode('Noise_IK_foo'));
      await a.mixHash(<int>[1]);
      await b.mixHash(<int>[1]);
      await a.mixKey(<int>[9, 9, 9]);
      await b.mixKey(<int>[9, 9, 9]);
      await a.mixHash(<int>[2]);
      await b.mixHash(<int>[2]);
      await a.mixKey(<int>[10, 10]);
      await b.mixKey(<int>[10, 10]);
      final sa = await a.split();
      final sb = await b.split();
      expect(sa.c1Key, equals(sb.c1Key));
      expect(sa.c2Key, equals(sb.c2Key));
    });
  });
}

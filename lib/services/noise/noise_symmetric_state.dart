/// Noise `SymmetricState` (spec §5.2) — the core state object shared by both
/// parties during a handshake. Accumulates the handshake hash `h` and
/// chaining key `ck`, derives an AEAD key `k` + nonce `n` from DH outputs,
/// and performs `EncryptAndHash` / `DecryptAndHash` on inline handshake
/// payloads.
///
/// One `SymmetricState` per handshake. Mutated in place; do not clone.
///
/// This file is a direct transcription of the Noise spec. Every method name
/// matches spec section 5.2; deviating in naming would make cross-referencing
/// with the spec PDF during review painful.
library;

import 'dart:typed_data';

import 'noise_primitives.dart';

class SymmetricState {
  /// Chaining key (64 bytes = noiseHashLen).
  Uint8List ck;

  /// Handshake hash (64 bytes).
  Uint8List h;

  /// AEAD key (32 bytes) when present; null means "no key yet".
  Uint8List? k;

  /// AEAD counter (Noise's `n`, 0..2^63 in practice).
  int n = 0;

  SymmetricState._(this.ck, this.h);

  /// `InitializeSymmetric(protocol_name)`:
  /// - if |protocol_name| <= HASHLEN, h = protocol_name || zeros
  /// - else h = HASH(protocol_name)
  /// - ck = h
  /// - k = EMPTY, n = 0
  static Future<SymmetricState> initialize(List<int> protocolName) async {
    Uint8List h;
    if (protocolName.length <= noiseHashLen) {
      h = Uint8List(noiseHashLen);
      h.setRange(0, protocolName.length, protocolName);
    } else {
      h = await noiseHash(protocolName);
    }
    final ck = Uint8List.fromList(h);
    return SymmetricState._(ck, h);
  }

  // ── Hash mixing ─────────────────────────────────────────────────────────

  /// `MixHash(data)`: h = HASH(h || data)
  Future<void> mixHash(List<int> data) async {
    final combined = Uint8List(h.length + data.length);
    combined.setRange(0, h.length, h);
    combined.setRange(h.length, combined.length, data);
    h = await noiseHash(combined);
  }

  /// `MixKey(input_key_material)`:
  /// - (ck, temp_k) = HKDF(ck, input_key_material, 2)
  /// - k = temp_k truncated to 32 bytes
  /// - n = 0
  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final outs = await noiseHkdf(
      chainingKey: ck,
      inputKeyMaterial: inputKeyMaterial,
      numOutputs: 2,
    );
    ck = outs[0];
    // Truncate to noiseKeyLen (32).
    k = Uint8List.fromList(outs[1].sublist(0, noiseKeyLen));
    n = 0;
  }

  /// `MixKeyAndHash(input_key_material)`:
  /// - (ck, temp_h, temp_k) = HKDF(ck, input_key_material, 3)
  /// - MixHash(temp_h)
  /// - k = temp_k truncated to 32 bytes
  /// - n = 0
  ///
  /// Not used by the IK pattern (no PSK), but included for completeness so
  /// that a future PSK-mode upgrade doesn't require touching this class.
  Future<void> mixKeyAndHash(List<int> inputKeyMaterial) async {
    final outs = await noiseHkdf(
      chainingKey: ck,
      inputKeyMaterial: inputKeyMaterial,
      numOutputs: 3,
    );
    ck = outs[0];
    await mixHash(outs[1]);
    k = Uint8List.fromList(outs[2].sublist(0, noiseKeyLen));
    n = 0;
  }

  bool get hasKey => k != null;

  // ── Encryption during handshake ────────────────────────────────────────

  /// `EncryptAndHash(plaintext)`:
  /// - if k is set: ciphertext = ENCRYPT(k, n++, h, plaintext)
  ///   else ciphertext = plaintext
  /// - MixHash(ciphertext)
  /// - return ciphertext
  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final key = k;
    Uint8List ct;
    if (key == null) {
      ct = Uint8List.fromList(plaintext);
    } else {
      ct = await noiseAeadEncrypt(
        key: key,
        counter: n,
        ad: h,
        plaintext: plaintext,
      );
      n += 1;
    }
    await mixHash(ct);
    return ct;
  }

  /// `DecryptAndHash(ciphertext)`:
  /// - if k is set: plaintext = DECRYPT(k, n++, h, ciphertext)
  ///   else plaintext = ciphertext
  /// - MixHash(ciphertext)
  /// - return plaintext
  ///
  /// NOTE: MixHash uses the CIPHERTEXT (not plaintext) even in the unkeyed
  /// branch. The spec is explicit about this; a bug here would silently
  /// desync handshake hashes and handshakes would fail with no clear cause.
  Future<Uint8List> decryptAndHash(List<int> ciphertext) async {
    final key = k;
    Uint8List pt;
    if (key == null) {
      pt = Uint8List.fromList(ciphertext);
    } else {
      pt = await noiseAeadDecrypt(
        key: key,
        counter: n,
        ad: h,
        ciphertextWithTag: ciphertext,
      );
      n += 1;
    }
    await mixHash(ciphertext);
    return pt;
  }

  // ── Split (transport key derivation) ───────────────────────────────────

  /// `Split()`: returns two CipherStates for transport traffic, one per
  /// direction. Caller decides which is `send` and which is `recv` based on
  /// initiator/responder role.
  ///
  /// On the initiator: `send = c1, recv = c2`.
  /// On the responder: `send = c2, recv = c1`.
  Future<({Uint8List c1Key, Uint8List c2Key})> split() async {
    final outs = await noiseHkdf(
      chainingKey: ck,
      inputKeyMaterial: <int>[],
      numOutputs: 2,
    );
    return (
      c1Key: Uint8List.fromList(outs[0].sublist(0, noiseKeyLen)),
      c2Key: Uint8List.fromList(outs[1].sublist(0, noiseKeyLen)),
    );
  }
}

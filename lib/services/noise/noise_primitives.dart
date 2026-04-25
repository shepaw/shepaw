/// Low-level cryptographic primitives for Noise_IK_25519_ChaChaPoly_BLAKE2b.
///
/// Thin adapters over the `cryptography` package that give the rest of the Noise
/// implementation byte-in / byte-out functions matching what the Noise spec
/// calls for. No Noise-specific state lives here; this file only knows how to
/// do ChaCha20-Poly1305, BLAKE2b, HMAC-BLAKE2b, HKDF-BLAKE2b, and X25519 DH.
///
/// Why a separate file: Noise primitives have very specific byte-level
/// conventions (nonce encoding, ad-before-ciphertext ordering, key+iv
/// concatenation shapes) that differ across libraries. Wrapping them here once
/// and testing them against Noise test vectors makes every higher-level
/// construction safer.
///
/// **IMPORTANT — nonce encoding for ChaCha20-Poly1305 in Noise:**
/// Noise uses a 64-bit little-endian counter `n`. RFC 7539 ChaCha20-Poly1305
/// uses a 12-byte nonce. Noise's convention (section 5.1 of the spec) is:
///
///     nonce_bytes = 4 zero bytes || LE64(n)    (total 12 bytes)
///
/// Every Noise implementation MUST use this exact encoding or handshakes will
/// silently produce different traffic keys than the peer.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

// ── Constants ─────────────────────────────────────────────────────────────

/// DH public key length in bytes (X25519 = 32).
const int noiseDhLen = 32;

/// Hash output length in bytes (BLAKE2b default digest used by Noise = 64).
const int noiseHashLen = 64;

/// AEAD key length (ChaCha20-Poly1305 = 32).
const int noiseKeyLen = 32;

/// AEAD auth tag length (Poly1305 = 16).
const int noiseTagLen = 16;

// ── Algorithm singletons ──────────────────────────────────────────────────

/// BLAKE2b-512 hash. Used directly and as the MAC inside HMAC.
///
/// Kept as a module-level singleton because instance construction inside hot
/// paths adds overhead and the algorithm is stateless.
final Blake2b _blake2b = Blake2b();

/// X25519 Diffie–Hellman. Stateless singleton.
final X25519 _x25519 = X25519();

/// ChaCha20-Poly1305 AEAD (RFC 7539, 12-byte nonce). Stateless singleton.
final Chacha20 _chachaPoly = Chacha20.poly1305Aead();

// ── Hash ───────────────────────────────────────────────────────────────────

/// Noise `HASH(data)` — returns 64 bytes (BLAKE2b-512).
Future<Uint8List> noiseHash(List<int> data) async {
  final h = await _blake2b.hash(data);
  if (h.bytes.length != noiseHashLen) {
    throw StateError('BLAKE2b produced ${h.bytes.length} bytes, expected $noiseHashLen');
  }
  return Uint8List.fromList(h.bytes);
}

// ── HMAC-BLAKE2b ──────────────────────────────────────────────────────────
//
// Noise's HMAC is defined generically over the chosen HASH function. We MUST
// implement HMAC from scratch — BLAKE2b has native keyed mode (via `mac()` in
// `cryptography`), but the Noise HMAC construction is explicitly *HMAC*, not
// keyed-BLAKE2b. These produce different outputs.
//
// HMAC per RFC 2104:
//   K' = key padded to blockLen (HASH(key) if key > blockLen, else key || zeros)
//   ipad = K' ^ 0x36 (each byte)
//   opad = K' ^ 0x5c (each byte)
//   HMAC(key, data) = HASH(opad || HASH(ipad || data))
//
// BLAKE2b block size = 128 bytes.

const int _blake2bBlockLen = 128;

/// HMAC-BLAKE2b(key, data) — 64-byte output.
Future<Uint8List> noiseHmac(List<int> key, List<int> data) async {
  // Step 1: Derive K' — pad (or hash-then-pad) the key to block length.
  Uint8List kPrime;
  if (key.length > _blake2bBlockLen) {
    final hashed = await noiseHash(key);
    kPrime = Uint8List(_blake2bBlockLen);
    kPrime.setRange(0, hashed.length, hashed);
  } else {
    kPrime = Uint8List(_blake2bBlockLen);
    kPrime.setRange(0, key.length, key);
  }

  // Step 2: ipad and opad.
  final inner = Uint8List(_blake2bBlockLen + data.length);
  final outerPrefix = Uint8List(_blake2bBlockLen);
  for (var i = 0; i < _blake2bBlockLen; i++) {
    inner[i] = kPrime[i] ^ 0x36;
    outerPrefix[i] = kPrime[i] ^ 0x5c;
  }
  inner.setRange(_blake2bBlockLen, inner.length, data);

  // Step 3: HASH(opad || HASH(ipad || data))
  final innerDigest = await noiseHash(inner);
  final outer = Uint8List(_blake2bBlockLen + innerDigest.length);
  outer.setRange(0, _blake2bBlockLen, outerPrefix);
  outer.setRange(_blake2bBlockLen, outer.length, innerDigest);

  return noiseHash(outer);
}

// ── HKDF ───────────────────────────────────────────────────────────────────

/// Noise HKDF (Noise spec §4.3). Produces `numOutputs` pseudorandom 64-byte
/// chunks derived from `chainingKey` + `inputKeyMaterial`.
///
/// Always returns a list of `numOutputs` Uint8Lists, each `noiseHashLen` (64)
/// bytes long. Callers truncate to the needed length themselves.
///
/// `numOutputs` must be 2 or 3 per the Noise spec. Other values are rejected.
Future<List<Uint8List>> noiseHkdf({
  required List<int> chainingKey,
  required List<int> inputKeyMaterial,
  required int numOutputs,
}) async {
  if (numOutputs < 2 || numOutputs > 3) {
    throw ArgumentError('noiseHkdf: numOutputs must be 2 or 3, got $numOutputs');
  }

  // temp_key = HMAC(chaining_key, input_key_material)
  final tempKey = await noiseHmac(chainingKey, inputKeyMaterial);

  // output1 = HMAC(temp_key, byte(0x01))
  final out1 = await noiseHmac(tempKey, <int>[0x01]);
  // output2 = HMAC(temp_key, output1 || byte(0x02))
  final out2Input = Uint8List(out1.length + 1);
  out2Input.setRange(0, out1.length, out1);
  out2Input[out1.length] = 0x02;
  final out2 = await noiseHmac(tempKey, out2Input);

  if (numOutputs == 2) return [out1, out2];

  // output3 = HMAC(temp_key, output2 || byte(0x03))
  final out3Input = Uint8List(out2.length + 1);
  out3Input.setRange(0, out2.length, out2);
  out3Input[out2.length] = 0x03;
  final out3 = await noiseHmac(tempKey, out3Input);
  return [out1, out2, out3];
}

// ── X25519 DH ──────────────────────────────────────────────────────────────

/// Generate a fresh X25519 keypair. Returns raw 32-byte private + public.
Future<({Uint8List privateKey, Uint8List publicKey})> noiseGenerateKeyPair() async {
  final pair = await _x25519.newKeyPair();
  final priv = await pair.extractPrivateKeyBytes();
  final pub = await pair.extractPublicKey();
  if (priv.length != noiseDhLen || pub.bytes.length != noiseDhLen) {
    throw StateError('X25519 produced unexpected key lengths');
  }
  return (
    privateKey: Uint8List.fromList(priv),
    publicKey: Uint8List.fromList(pub.bytes),
  );
}

/// Derive the X25519 public key for a given 32-byte private scalar.
///
/// Useful when restoring an identity from storage (we stored priv + pub
/// together, but this lets tests and future revocation flows re-derive).
Future<Uint8List> noiseDerivePublic(List<int> privateKey) async {
  if (privateKey.length != noiseDhLen) {
    throw ArgumentError('privateKey must be $noiseDhLen bytes');
  }
  // `cryptography`'s `newKeyPairFromSeed` recomputes the public key from the
  // 32-byte private scalar, which is exactly what we need.
  final rebuilt = await _x25519.newKeyPairFromSeed(privateKey);
  final pub = await rebuilt.extractPublicKey();
  return Uint8List.fromList(pub.bytes);
}

/// Noise `DH(privateKey, publicKey)` — X25519 scalar multiplication.
/// Output: 32-byte raw shared secret.
Future<Uint8List> noiseDh({
  required List<int> privateKey,
  required List<int> remotePublicKey,
}) async {
  if (privateKey.length != noiseDhLen) {
    throw ArgumentError('privateKey must be $noiseDhLen bytes');
  }
  if (remotePublicKey.length != noiseDhLen) {
    throw ArgumentError('remotePublicKey must be $noiseDhLen bytes');
  }

  // `cryptography`'s API wants us to turn the private scalar into a SimpleKeyPair.
  // It'll recompute the public from the private when we pass through; we don't
  // need the public here but the API requires a keypair object.
  final myPair = await _x25519.newKeyPairFromSeed(privateKey);
  final theirPub = SimplePublicKey(remotePublicKey, type: KeyPairType.x25519);

  final sharedSecretKey = await _x25519.sharedSecretKey(
    keyPair: myPair,
    remotePublicKey: theirPub,
  );
  final bytes = await sharedSecretKey.extractBytes();
  if (bytes.length != noiseDhLen) {
    throw StateError('X25519 DH produced ${bytes.length} bytes, expected $noiseDhLen');
  }
  return Uint8List.fromList(bytes);
}

// ── AEAD: ChaCha20-Poly1305 ────────────────────────────────────────────────

/// Encode a Noise 64-bit counter as the 12-byte RFC 7539 nonce:
///
///     [0, 0, 0, 0, n_le[0..7]]
///
/// Noise spec §5.1. Getting this wrong produces subtly incompatible
/// ciphertexts.
Uint8List noiseNonceBytes(int counter) {
  if (counter < 0) {
    throw ArgumentError('noise nonce counter must be non-negative');
  }
  final b = Uint8List(12);
  // 4 zero bytes (b[0..3]) are already zero; encode counter as LE64 at b[4..11].
  var c = counter;
  for (var i = 0; i < 8; i++) {
    b[4 + i] = c & 0xff;
    c = (c >> 8);
  }
  return b;
}

/// Noise `ENCRYPT(k, n, ad, plaintext)` — returns ciphertext || 16-byte tag.
Future<Uint8List> noiseAeadEncrypt({
  required List<int> key,
  required int counter,
  required List<int> ad,
  required List<int> plaintext,
}) async {
  if (key.length != noiseKeyLen) {
    throw ArgumentError('key must be $noiseKeyLen bytes');
  }
  final nonce = noiseNonceBytes(counter);
  final box = await _chachaPoly.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: ad,
  );
  // Noise wire format is ciphertext || MAC.
  final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
  out.setRange(0, box.cipherText.length, box.cipherText);
  out.setRange(box.cipherText.length, out.length, box.mac.bytes);
  return out;
}

/// Noise `DECRYPT(k, n, ad, ciphertext)` — where `ciphertext` is wire-format
/// `actual_ciphertext || tag`. Returns the decrypted plaintext.
///
/// Throws a [NoiseAeadFailure] if authentication fails.
Future<Uint8List> noiseAeadDecrypt({
  required List<int> key,
  required int counter,
  required List<int> ad,
  required List<int> ciphertextWithTag,
}) async {
  if (key.length != noiseKeyLen) {
    throw ArgumentError('key must be $noiseKeyLen bytes');
  }
  if (ciphertextWithTag.length < noiseTagLen) {
    throw NoiseAeadFailure('ciphertext too short to contain tag');
  }

  final nonce = noiseNonceBytes(counter);
  final ctLen = ciphertextWithTag.length - noiseTagLen;
  // Copy to detach from caller ownership; avoids surprising mutation semantics.
  final cipherBytes = Uint8List.fromList(ciphertextWithTag.sublist(0, ctLen));
  final macBytes = Uint8List.fromList(ciphertextWithTag.sublist(ctLen));

  final box = SecretBox(cipherBytes, nonce: nonce, mac: Mac(macBytes));
  try {
    final pt = await _chachaPoly.decrypt(box, secretKey: SecretKey(key), aad: ad);
    return Uint8List.fromList(pt);
  } on SecretBoxAuthenticationError catch (e) {
    throw NoiseAeadFailure('AEAD authentication failed: ${e.message}');
  }
}

/// Thrown by [noiseAeadDecrypt] when authentication fails. Callers should
/// treat this as a fatal session error and close the connection — never echo
/// the underlying reason to the peer (oracle risk).
class NoiseAeadFailure implements Exception {
  final String message;
  NoiseAeadFailure(this.message);
  @override
  String toString() => 'NoiseAeadFailure: $message';
}

/// Sealed box for channel mailbox — wire-compatible with agent-bridge `sealbox.ts`.
///
/// Format (version 1):
///   0x01 || ephemeral_pub(32) || nonce(12) || ciphertext||tag(16)
///
/// KEM: ephemeral X25519 × recipient static public key
/// KDF: HKDF-SHA256(shared, salt="shepaw-mailbox-v1", info="seal", len=32)
/// AEAD: ChaCha20-Poly1305
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../noise/noise_primitives.dart';

const int _version = 0x01;
const int _ephLen = 32;
const int _nonceLen = 12;
const int _tagLen = 16;
const int _headerLen = 1 + _ephLen + _nonceLen;

final _salt = utf8.encode('shepaw-mailbox-v1');
final _info = utf8.encode('seal');
final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
final _aead = Chacha20.poly1305Aead();
final _x25519 = X25519();

class MailboxSealException implements Exception {
  MailboxSealException(this.message);
  final String message;
  @override
  String toString() => 'MailboxSealException: $message';
}

/// Seal [plaintext] to [recipientPublicKey] (32-byte raw X25519).
Future<Uint8List> mailboxSeal(
  Uint8List plaintext,
  Uint8List recipientPublicKey,
) async {
  if (recipientPublicKey.length != 32) {
    throw MailboxSealException(
      'recipient public key must be 32 bytes (got ${recipientPublicKey.length})',
    );
  }

  final ephPair = await _x25519.newKeyPair();
  final ephPub = Uint8List.fromList(
    (await ephPair.extractPublicKey()).bytes,
  );
  final ephPriv = Uint8List.fromList(await ephPair.extractPrivateKeyBytes());

  final shared = await noiseDh(
    privateKey: ephPriv,
    remotePublicKey: recipientPublicKey,
  );
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: _salt,
    info: _info,
  );
  final nonce = _aead.newNonce(); // 12 bytes
  if (nonce.length != _nonceLen) {
    throw MailboxSealException('unexpected nonce length ${nonce.length}');
  }

  final box = await _aead.encrypt(
    plaintext,
    secretKey: key,
    nonce: nonce,
  );

  final out = Uint8List(_headerLen + box.cipherText.length + _tagLen);
  out[0] = _version;
  out.setAll(1, ephPub);
  out.setAll(1 + _ephLen, nonce);
  out.setAll(_headerLen, box.cipherText);
  out.setAll(_headerLen + box.cipherText.length, box.mac.bytes);
  return out;
}

/// Open a sealed box with the recipient's 32-byte raw private key.
Future<Uint8List> mailboxOpen(
  Uint8List sealed,
  Uint8List recipientPrivateKey,
) async {
  if (recipientPrivateKey.length != 32) {
    throw MailboxSealException(
      'recipient private key must be 32 bytes (got ${recipientPrivateKey.length})',
    );
  }
  if (sealed.length < _headerLen + _tagLen) {
    throw MailboxSealException('sealed box too short');
  }
  if (sealed[0] != _version) {
    throw MailboxSealException('unsupported seal version ${sealed[0]}');
  }

  final ephPub = sealed.sublist(1, 1 + _ephLen);
  final nonce = sealed.sublist(1 + _ephLen, _headerLen);
  final ctAndTag = sealed.sublist(_headerLen);
  final ct = ctAndTag.sublist(0, ctAndTag.length - _tagLen);
  final tag = ctAndTag.sublist(ctAndTag.length - _tagLen);

  final shared = await noiseDh(
    privateKey: recipientPrivateKey,
    remotePublicKey: ephPub,
  );
  final key = await _hkdf.deriveKey(
    secretKey: SecretKey(shared),
    nonce: _salt,
    info: _info,
  );

  try {
    final clear = await _aead.decrypt(
      SecretBox(ct, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
    );
    return Uint8List.fromList(clear);
  } catch (e) {
    throw MailboxSealException('decryption failed: $e');
  }
}

Future<String> mailboxSealJson(
  Map<String, dynamic> obj,
  Uint8List recipientPublicKey,
) async {
  final plain = Uint8List.fromList(utf8.encode(jsonEncode(obj)));
  final sealed = await mailboxSeal(plain, recipientPublicKey);
  return base64Encode(sealed);
}

Future<Map<String, dynamic>> mailboxOpenJson(
  String ciphertextB64,
  Uint8List recipientPrivateKey,
) async {
  final sealed = base64Decode(ciphertextB64);
  final plain = await mailboxOpen(Uint8List.fromList(sealed), recipientPrivateKey);
  final decoded = jsonDecode(utf8.decode(plain));
  if (decoded is! Map<String, dynamic>) {
    throw MailboxSealException('payload is not a JSON object');
  }
  return decoded;
}

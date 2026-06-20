/// Ed25519 long-term identity for User and SpiritPet domains.
///
/// Separate from [NoiseIdentity] (X25519 device transport key). User / SpiritPet
/// keys are used for ownership bonds, sync event signatures, and device trust.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto_hash;
import 'package:cryptography/cryptography.dart';

import '../../services/logger_service.dart';
import '../../services/secure_key_manager.dart';

class Ed25519Identity {
  final Uint8List publicKey;
  final Uint8List privateKey;
  final int? createdAtMs;

  const Ed25519Identity._({
    required this.publicKey,
    required this.privateKey,
    required this.createdAtMs,
  });

  static final Map<String, Ed25519Identity?> _caches = {};

  /// 16-hex fingerprint: SHA-256(publicKey) first 8 bytes.
  String get fingerprintHex {
    final digest = crypto_hash.sha256.convert(publicKey).bytes;
    final sb = StringBuffer();
    for (var i = 0; i < 8; i++) {
      sb.write(digest[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  String get publicKeyBase64 => base64.encode(publicKey);

  SimpleKeyPairData toKeyPairData() {
    return SimpleKeyPairData(
      privateKey,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      type: KeyPairType.ed25519,
    );
  }

  SimplePublicKey toPublicKey() {
    return SimplePublicKey(publicKey, type: KeyPairType.ed25519);
  }

  Future<Uint8List> signBytes(Uint8List message) async {
    final algorithm = Ed25519();
    final signature = await algorithm.sign(message, keyPair: toKeyPairData());
    return Uint8List.fromList(signature.bytes);
  }

  Future<Uint8List> signUtf8(String message) => signBytes(utf8.encode(message));

  static Future<bool> verifyBytes({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    if (publicKey.length != 32 || signature.length != 64) return false;
    final algorithm = Ed25519();
    return algorithm.verify(
      message,
      signature: Signature(signature, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  }

  static Future<bool> verifyUtf8({
    required String message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) =>
      verifyBytes(message: utf8.encode(message), signature: signature, publicKey: publicKey);

  static Future<Ed25519Identity> loadOrCreate(String storageKey) async {
    final cached = _caches[storageKey];
    if (cached != null) return cached;

    final existing = await SecureKeyManager.getSecureValue(storageKey);
    if (existing != null && existing.isNotEmpty) {
      final parsed = parseRecord(existing);
      _caches[storageKey] = parsed;
      return parsed;
    }

    final fresh = await _generate();
    await SecureKeyManager.saveSecureValue(storageKey, fresh.encodeRecord());
    _caches[storageKey] = fresh;
    LoggerService().info(
      'Generated Ed25519 identity (fp=${fresh.fingerprintHex}) key=$storageKey',
      tag: 'Identity',
    );
    return fresh;
  }

  static Future<Ed25519Identity> importRecord(String storageKey, String record) async {
    final parsed = parseRecord(record);
    await SecureKeyManager.saveSecureValue(storageKey, record);
    _caches[storageKey] = parsed;
    return parsed;
  }

  static Ed25519Identity fromRawBytes({
    required Uint8List publicKey,
    required Uint8List privateKey,
    int? createdAtMs,
  }) {
    if (publicKey.length != 32) {
      throw ArgumentError('publicKey must be 32 bytes, got ${publicKey.length}');
    }
    if (privateKey.length != 32) {
      throw ArgumentError('privateKey must be 32 bytes, got ${privateKey.length}');
    }
    return Ed25519Identity._(
      publicKey: publicKey,
      privateKey: privateKey,
      createdAtMs: createdAtMs,
    );
  }

  String encodeRecord() {
    final priv = base64.encode(privateKey);
    final pub = base64.encode(publicKey);
    final ts = createdAtMs ?? DateTime.now().toUtc().millisecondsSinceEpoch;
    return 'v1.$priv.$pub.$ts';
  }

  static Ed25519Identity parseRecord(String raw) {
    final parts = raw.split('.');
    if (parts.isEmpty || parts[0] != 'v1') {
      throw FormatException('unknown record version: ${parts.isEmpty ? "<empty>" : parts[0]}');
    }
    if (parts.length != 3 && parts.length != 4) {
      throw FormatException('v1 record must have 3 or 4 parts, got ${parts.length}');
    }
    final priv = base64.decode(parts[1]);
    final pub = base64.decode(parts[2]);
    int? ts;
    if (parts.length == 4) {
      ts = int.tryParse(parts[3]);
      if (ts == null) throw FormatException('invalid timestamp: ${parts[3]}');
    }
    return fromRawBytes(publicKey: Uint8List.fromList(pub), privateKey: Uint8List.fromList(priv), createdAtMs: ts);
  }

  static Future<Ed25519Identity> _generate() async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    final pub = await keyPair.extractPublicKey();
    return Ed25519Identity._(
      publicKey: Uint8List.fromList(pub.bytes),
      privateKey: Uint8List.fromList(privBytes),
      createdAtMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

}

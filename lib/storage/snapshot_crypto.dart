import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../services/secure_key_manager.dart';

/// 快照加解密错误（密码错误或数据被篡改——Poly1305 MAC 校验失败）。
class SnapshotDecryptException implements Exception {
  SnapshotDecryptException([this.message = 'decrypt failed (wrong password or tampered data)']);
  final String message;
  @override
  String toString() => 'SnapshotDecryptException: $message';
}

/// 快照加密层（docs/storage_space_plan.md §5.2，M3 修订）。
///
/// 两级 KDF：
/// ```
/// H   = PBKDF2-HMAC-SHA256(主密码, 静态域 salt, 120k 轮)   ← 慢，可缓存
/// key = SHA-256("shepaw.snapshot.key" ‖ H ‖ snapshot_salt) ← 快，随快照随机
/// ```
/// - **snapshot_salt 随快照生成并记录在 manifest**——换机恢复时新设备凭
///   主密码即可重建密钥（M1 的设备 salt 方案在换机后新设备拿不到 salt，
///   无法解密旧机快照，M3 修复）。
/// - H 经 [cachePasswordHash] 持久化到 SecureKeyManager：定期自动快照
///   无需每次询问密码；改密后缓存失效。
/// - 密文格式：XChaCha20-Poly1305，nonce(24)‖ct‖mac(16)。
class SnapshotCrypto {
  SnapshotCrypto._();

  static const String _hashStorageKey = 'shepaw.storage.password_hash.v1';
  static const String _legacySaltStorageKey = 'shepaw.storage.snapshot_salt.v1';
  static const int _pbkdf2Iterations = 120000;
  static const int _keyBits = 256;
  static const _hashDomain = 'shepaw.storage.v1';
  static const _keyDomain = 'shepaw.snapshot.key';

  static final _aead = Xchacha20.poly1305Aead();

  // ────────────────────────────── 两级 KDF ──

  /// 主密码 → 密码哈希 H（慢路径，结果可缓存）。
  static Future<Uint8List> hashPassword(String password) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: _keyBits,
    );
    final key = await kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: utf8.encode(_hashDomain),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// 生成新的 snapshot salt（每快照随机）。
  static Uint8List newSnapshotSalt() => Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)));

  /// H + snapshot_salt → 快照加密密钥（快路径）。
  static Future<SecretKey> deriveKeyFromHash(
      Uint8List passwordHash, Uint8List snapshotSalt) async {
    final hmac = Hmac(Sha256());
    final mac = await hmac.calculateMac(
      Uint8List.fromList([...utf8.encode(_keyDomain), ...snapshotSalt]),
      secretKey: SecretKey(passwordHash),
    );
    return SecretKey(mac.bytes);
  }

  /// 主密码 + snapshot_salt → 快照加密密钥（慢路径，恢复/手动操作用）。
  static Future<SecretKey> deriveKeyFromPassword(
      String password, Uint8List snapshotSalt) async {
    final h = await hashPassword(password);
    return deriveKeyFromHash(h, snapshotSalt);
  }

  // ─────────────────────── 缓存的密码哈希（自动快照用）──

  /// 验密成功后缓存 H（SecureKeyManager，随系统 keychain 存续）。
  static Future<void> cachePasswordHash(Uint8List h) async {
    await SecureKeyManager.saveSecureValue(_hashStorageKey, base64.encode(h));
  }

  static Future<Uint8List?> cachedPasswordHash() async {
    final v = await SecureKeyManager.getSecureValue(_hashStorageKey);
    if (v == null || v.isEmpty) return null;
    return Uint8List.fromList(base64.decode(v));
  }

  /// 改密/重置后失效缓存。
  static Future<void> clearCachedPasswordHash() async {
    await SecureKeyManager.deleteSecureValue(_hashStorageKey);
  }

  // ─────────────────────── M1 旧格式兼容（设备 salt）──

  /// M1 快照的设备 salt（旧 manifest 无 kdf_salt 字段时使用）。
  static Future<Uint8List> legacyDeviceSalt() async {
    final existing =
        await SecureKeyManager.getSecureValue(_legacySaltStorageKey);
    if (existing != null && existing.isNotEmpty) {
      return Uint8List.fromList(base64.decode(existing));
    }
    final salt = newSnapshotSalt();
    await SecureKeyManager.saveSecureValue(
        _legacySaltStorageKey, base64.encode(salt));
    return salt;
  }

  /// M1 旧格式密钥：PBKDF2(密码, 设备 salt)。
  static Future<SecretKey> deriveLegacyKey(String password) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: _keyBits,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: await legacyDeviceSalt(),
    );
  }

  // ────────────────────────────── 加解密 ──

  /// 加密，返回 nonce‖ciphertext‖mac 打包字节。
  static Future<Uint8List> encrypt(Uint8List plain, SecretKey key) async {
    final box = await _aead.encrypt(plain, secretKey: key);
    return box.concatenation();
  }

  /// 解密。密码错误或数据被篡改时抛 [SnapshotDecryptException]。
  static Future<Uint8List> decrypt(Uint8List packed, SecretKey key) async {
    try {
      final box = SecretBox.fromConcatenation(
        packed,
        nonceLength: 24,
        macLength: 16,
      );
      final plain = await _aead.decrypt(box, secretKey: key);
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw SnapshotDecryptException();
    }
  }
}

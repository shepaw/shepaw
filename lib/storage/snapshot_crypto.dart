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

/// 快照加密层（docs/storage_space_plan.md §5.2）。
///
/// - 算法：XChaCha20-Poly1305（随机 24B nonce，密文 = nonce‖ct‖mac）。
/// - 密钥：PBKDF2-HMAC-SHA256（主密码，设备 salt，120k 轮，256bit）。
/// - 设备 salt：随机 32B，经 SecureKeyManager 持久化，重装后随系统
///   keychain/安全存储存续；丢失只影响旧快照可解密性（主密码仍在即可重新
///   生成新 salt 做新快照）。
class SnapshotCrypto {
  SnapshotCrypto._();

  static const String _saltStorageKey = 'shepaw.storage.snapshot_salt.v1';
  static const int _pbkdf2Iterations = 120000;
  static const int _keyBits = 256;

  static final _aead = Xchacha20.poly1305Aead();

  /// 读取或生成设备 salt。
  static Future<Uint8List> deviceSalt() async {
    final existing = await SecureKeyManager.getSecureValue(_saltStorageKey);
    if (existing != null && existing.isNotEmpty) {
      return Uint8List.fromList(base64.decode(existing));
    }
    final salt = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    await SecureKeyManager.saveSecureValue(_saltStorageKey, base64.encode(salt));
    return salt;
  }

  /// 从主密码派生快照密钥。
  static Future<SecretKey> deriveKey(String password) async {
    final kdf = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _pbkdf2Iterations,
      bits: _keyBits,
    );
    return kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: await deviceSalt(),
    );
  }

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

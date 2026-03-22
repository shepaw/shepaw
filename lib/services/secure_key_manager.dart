import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:encrypt/encrypt.dart' as encrypt;

/// 安全密钥管理服务
/// 使用 Flutter Secure Storage 安全存储加密密钥
class SecureKeyManager {
  static const _storage = FlutterSecureStorage();
  static const String _encryptionKeyName = 'app_encryption_key';
  static const String _encryptionIVName = 'app_encryption_iv';
  
  /// 获取或生成加密密钥
  static Future<encrypt.Key> getEncryptionKey() async {
    String? keyString = await _storage.read(key: _encryptionKeyName);
    
    if (keyString == null) {
      // 首次使用，生成新密钥
      final key = _generateSecureKey(32);
      await _storage.write(
        key: _encryptionKeyName,
        value: key,
      );
      return encrypt.Key.fromBase64(key);
    }
    
    return encrypt.Key.fromBase64(keyString);
  }
  
  /// 获取或生成 IV
  static Future<encrypt.IV> getEncryptionIV() async {
    String? ivString = await _storage.read(key: _encryptionIVName);
    
    if (ivString == null) {
      // 首次使用，生成新 IV
      final iv = _generateSecureKey(16);
      await _storage.write(
        key: _encryptionIVName,
        value: iv,
      );
      return encrypt.IV.fromBase64(iv);
    }
    
    return encrypt.IV.fromBase64(ivString);
  }
  
  /// 生成安全的随机密钥
  static String _generateSecureKey(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return encrypt.Encrypter(encrypt.AES(encrypt.Key(bytes)))
        .encrypt('', iv: encrypt.IV.fromLength(16))
        .base64
        .substring(0, length);
  }
  
  /// 清除所有密钥（退出登录/重置应用时使用）
  static Future<void> clearAllKeys() async {
    await _storage.delete(key: _encryptionKeyName);
    await _storage.delete(key: _encryptionIVName);
  }
}

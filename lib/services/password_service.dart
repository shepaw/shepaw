import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:shared_preferences/shared_preferences.dart';
import 'logger_service.dart';

/// 密码管理服务
/// 负责密码的加密存储、验证和管理
class PasswordService {
  static const String _passwordHashKey = 'user_password_hash';
  static const String _passwordSaltKey = 'user_password_salt';
  static const String _isPasswordSetKey = 'is_password_set';
  
  // AES 加密密钥（实际生产环境应该更安全地管理）
  static const String _encryptionKey = 'shepaw-secure-key-32characters';
  
  late SharedPreferences _prefs;
  
  /// 初始化服务
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }
  
  /// 检查是否已设置密码
  Future<bool> isPasswordSet() async {
    return _prefs.getBool(_isPasswordSetKey) ?? false;
  }
  
  /// 设置密码（首次设置）
  Future<bool> setPassword(String password) async {
    if (password.isEmpty || password.length < 6) {
      return false; // 密码长度至少6位
    }
    
    try {
      // 生成随机盐值
      final salt = _generateSalt();
      
      // 使用盐值和密码生成哈希
      final hash = _hashPassword(password, salt);
      
      // 保存哈希和盐值
      await _prefs.setString(_passwordHashKey, hash);
      await _prefs.setString(_passwordSaltKey, salt);
      await _prefs.setBool(_isPasswordSetKey, true);
      
      return true;
    } catch (e) {
      LoggerService().error('Failed to set password', tag: 'Password', error: e);
      return false;
    }
  }
  
  /// 验证密码
  Future<bool> verifyPassword(String password) async {
    try {
      final savedHash = _prefs.getString(_passwordHashKey);
      final salt = _prefs.getString(_passwordSaltKey);
      
      if (savedHash == null || salt == null) {
        return false;
      }
      
      // 使用相同的盐值计算输入密码的哈希
      final inputHash = _hashPassword(password, salt);
      
      // 比较哈希值
      return inputHash == savedHash;
    } catch (e) {
      LoggerService().error('Failed to verify password', tag: 'Password', error: e);
      return false;
    }
  }
  
  /// 修改密码
  Future<bool> changePassword(String oldPassword, String newPassword) async {
    // 验证旧密码
    final isOldPasswordCorrect = await verifyPassword(oldPassword);
    if (!isOldPasswordCorrect) {
      return false;
    }
    
    // 设置新密码
    return await setPassword(newPassword);
  }
  
  /// 重置密码（需要特殊权限或验证）
  Future<void> resetPassword() async {
    await _prefs.remove(_passwordHashKey);
    await _prefs.remove(_passwordSaltKey);
    await _prefs.setBool(_isPasswordSetKey, false);
  }
  
  /// 生成随机盐值
  String _generateSalt() {
    final random = DateTime.now().millisecondsSinceEpoch.toString();
    return base64Encode(utf8.encode(random));
  }
  
  /// 使用 SHA-256 和盐值生成密码哈希
  String _hashPassword(String password, String salt) {
    final bytes = utf8.encode(password + salt);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }
  
  /// 加密数据（用于敏感数据存储）
  String encryptData(String data) {
    final key = encrypt.Key.fromUtf8(_encryptionKey);
    final iv = encrypt.IV.fromLength(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(key));
    
    final encrypted = encrypter.encrypt(data, iv: iv);
    return encrypted.base64;
  }
  
  /// 解密数据
  String decryptData(String encryptedData) {
    final key = encrypt.Key.fromUtf8(_encryptionKey);
    final iv = encrypt.IV.fromLength(16);
    final encrypter = encrypt.Encrypter(encrypt.AES(key));
    
    final decrypted = encrypter.decrypt64(encryptedData, iv: iv);
    return decrypted;
  }
}

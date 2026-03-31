import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'local_database_service.dart';
import 'logger_service.dart';
import 'vault_service.dart';

/// 密码管理服务
/// 负责密码的加密存储、验证和管理
/// 敏感数据存储于 SQLite user 表（KV 结构），不再使用 SharedPreferences
class PasswordService {
  static const String _passwordHashKey = 'password_hash';
  static const String _passwordSaltKey = 'password_salt';
  static const String _isPasswordSetKey = 'is_password_set';

  // AES 加密密钥（实际生产环境应该更安全地管理）
  static const String _encryptionKey = 'shepaw-secure-key-32characters';

  final _db = LocalDatabaseService();

  /// 检查是否已设置密码
  Future<bool> isPasswordSet() async {
    final value = await _db.getUserValue(_isPasswordSetKey);
    return value == 'true';
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

      // 保存哈希和盐值到 user KV 表
      await _db.setUserValue(_passwordHashKey, hash);
      await _db.setUserValue(_passwordSaltKey, salt);
      await _db.setUserValue(_isPasswordSetKey, 'true');

      return true;
    } catch (e) {
      LoggerService().error('Failed to set password', tag: 'Password', error: e);
      return false;
    }
  }

  /// 验证密码
  Future<bool> verifyPassword(String password) async {
    try {
      final savedHash = await _db.getUserValue(_passwordHashKey);
      final salt = await _db.getUserValue(_passwordSaltKey);

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

  /// 获取当前密码凭证（用于创建 vault 的加密密钥派生）
  ///
  /// 返回 `{'hash': ..., 'salt': ...}`，不存在时对应值为 null。
  Future<Map<String, String?>> getPasswordCredentials() async {
    final hash = await _db.getUserValue(_passwordHashKey);
    final salt = await _db.getUserValue(_passwordSaltKey);
    return {'hash': hash, 'salt': salt};
  }

  /// 重置密码
  ///
  /// 重置流程：
  ///   1. 将旧数据库打包成加密 vault 文件（以旧密码 hash 为密钥）
  ///   2. 删除所有 DB 文件（shepaw.db、she_profile.db 等）
  ///   3. 清除密码记录（is_password_set → false）
  ///
  /// 调用后下次访问数据库时会自动创建空白数据库。
  Future<void> resetPassword() async {
    // Step 1: 备份旧数据到 vault
    try {
      final creds = await getPasswordCredentials();
      if (creds['hash'] != null) {
        final vaultService = VaultService();
        await vaultService.createVault(
          passwordHash: creds['hash']!,
          salt: creds['salt'] ?? '',
        );
      }
    } catch (e) {
      LoggerService().error('Failed to create vault during reset', tag: 'Password', error: e);
      // vault 创建失败不阻塞重置流程，继续执行
    }

    // Step 2: 删除所有 DB 文件
    try {
      await LocalDatabaseService.clearAllDatabases();
    } catch (e) {
      LoggerService().error('Failed to clear databases during reset', tag: 'Password', error: e);
    }

    // Step 3: 重新初始化主库并清除密码记录
    // 注意：clearAllDatabases 已删除文件，此处访问 _db 会自动重建空库
    await _db.deleteUserValue(_passwordHashKey);
    await _db.deleteUserValue(_passwordSaltKey);
    await _db.setUserValue(_isPasswordSetKey, 'false');
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

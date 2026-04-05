import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:path_provider/path_provider.dart';

/// 安全密钥管理服务
///
/// 实现：AES-256-CBC 加密后写文件（沙箱 Application Support 目录）。
/// 背景：macOS 沙箱应用在无开发者证书时，flutter_secure_storage 写 Keychain 静默失败。
/// 本实现用 path_provider 获取沙箱专属目录，数据不出沙箱，其他进程无法访问。
///
/// 文件布局（Application Support/com.shepaw.app/secure/）：
///   _master.key  — 随机 AES-256 key + IV（96 bytes raw），首次生成后持久化
///   _secrets.json — AES 加密后的 base64，明文为 JSON Map<String, String>
class SecureKeyManager {
  static const String _secureDir = 'secure';
  static const String _masterKeyFile = '_master.key';
  static const String _secretsFile = '_secrets.json';

  // ── 内部路径辅助 ──────────────────────────────────────────────────────────

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_secureDir');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  // ── Master Key 管理 ───────────────────────────────────────────────────────

  /// 获取（或初次生成）AES key + IV，存在沙箱文件中。
  static Future<({encrypt.Key key, encrypt.IV iv})> _getMasterKey() async {
    final dir = await _dir();
    final keyFile = File('${dir.path}/$_masterKeyFile');

    if (keyFile.existsSync()) {
      final bytes = await keyFile.readAsBytes();
      // 格式：前 32 字节为 key，后 16 字节为 IV
      if (bytes.length >= 48) {
        final key = encrypt.Key(bytes.sublist(0, 32));
        final iv = encrypt.IV(bytes.sublist(32, 48));
        return (key: key, iv: iv);
      }
    }

    // 首次：生成随机 key（32B）和 IV（16B）
    final rng = Random.secure();
    final keyBytes = Uint8List(32);
    final ivBytes = Uint8List(16);
    for (var i = 0; i < 32; i++) { keyBytes[i] = rng.nextInt(256); }
    for (var i = 0; i < 16; i++) { ivBytes[i] = rng.nextInt(256); }

    final combined = Uint8List(48)
      ..setRange(0, 32, keyBytes)
      ..setRange(32, 48, ivBytes);
    await keyFile.writeAsBytes(combined, flush: true);

    return (
      key: encrypt.Key(keyBytes),
      iv: encrypt.IV(ivBytes),
    );
  }

  // ── Secrets 文件读写 ──────────────────────────────────────────────────────

  static Future<Map<String, String>> _readAll() async {
    final dir = await _dir();
    final file = File('${dir.path}/$_secretsFile');
    if (!file.existsSync()) return {};

    try {
      final master = await _getMasterKey();
      final encrypter = encrypt.Encrypter(encrypt.AES(master.key));
      final cipherText = await file.readAsString();
      final decrypted = encrypter.decrypt64(cipherText, iv: master.iv);
      final map = jsonDecode(decrypted) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      // 文件损坏或首次读取失败，返回空 map
      return {};
    }
  }

  static Future<void> _writeAll(Map<String, String> data) async {
    final dir = await _dir();
    final file = File('${dir.path}/$_secretsFile');
    final master = await _getMasterKey();
    final encrypter = encrypt.Encrypter(encrypt.AES(master.key));
    final plainText = jsonEncode(data);
    final encrypted = encrypter.encrypt(plainText, iv: master.iv);
    await file.writeAsString(encrypted.base64, flush: true);
  }

  // ── 通用 Secure KV 存储（与原 API 完全兼容）──────────────────────────────

  /// 安全存储任意字符串值
  static Future<void> saveSecureValue(String key, String value) async {
    final all = await _readAll();
    all[key] = value;
    await _writeAll(all);
  }

  /// 读取安全存储的字符串值
  static Future<String?> getSecureValue(String key) async {
    final all = await _readAll();
    return all[key];
  }

  /// 删除安全存储的值
  static Future<void> deleteSecureValue(String key) async {
    final all = await _readAll();
    if (all.remove(key) != null) {
      await _writeAll(all);
    }
  }

  /// 读取所有安全存储的键值对
  static Future<Map<String, String>> getAllSecureValues() async {
    return _readAll();
  }

  // ── 工具 Secret 命名规范 ──────────────────────────────────────────────────

  /// 工具 secret 字段的存储键名格式
  /// 格式：tool_secret_<toolName>_<fieldKey>，支持同一工具多个 secret 字段
  static String toolSecretStorageKey(String toolName, String fieldKey) =>
      'tool_secret_${toolName}_$fieldKey';

  // ── 遗留兼容（旧代码引用，当前不再使用）─────────────────────────────────

  /// 已废弃：原 Keychain 加密密钥操作，保留签名避免编译错误
  @Deprecated('Keychain 存储已废弃，请使用 saveSecureValue/getSecureValue')
  static Future<encrypt.Key> getEncryptionKey() async {
    final master = await _getMasterKey();
    return master.key;
  }

  @Deprecated('Keychain 存储已废弃，请使用 saveSecureValue/getSecureValue')
  static Future<encrypt.IV> getEncryptionIV() async {
    final master = await _getMasterKey();
    return master.iv;
  }

  @Deprecated('Keychain 存储已废弃')
  static Future<void> clearAllKeys() async {
    final dir = await _dir();
    final keyFile = File('${dir.path}/$_masterKeyFile');
    final secretsFile = File('${dir.path}/$_secretsFile');
    if (keyFile.existsSync()) await keyFile.delete();
    if (secretsFile.existsSync()) await secretsFile.delete();
  }
}

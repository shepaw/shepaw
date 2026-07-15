import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

/// 安全密钥管理服务
///
/// 优先将 AES master key 存入平台 Secure Storage（Keychain / Keystore）。
/// 若平台存储不可用（例如无开发者证书的 macOS 沙箱），回退到 Application
/// Support 目录下的加密文件布局。
///
/// 文件布局（回退模式，Application Support/com.shepaw.app/secure/）：
///   _master.key  — 随机 AES-256 key + IV（48 bytes raw）
///   _secrets.json — AES 加密后的 base64，明文为 JSON Map<String, String>
class SecureKeyManager {
  static const String _secureDir = 'secure';
  static const String _masterKeyFile = '_master.key';
  static const String _secretsFile = '_secrets.json';
  static const String _masterKeyStorageKey = 'shepaw_secure_master_key_v1';

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ── 内部路径辅助 ──────────────────────────────────────────────────────────

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_secureDir');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  // ── Master Key 管理 ───────────────────────────────────────────────────────

  /// 获取（或初次生成）AES key + IV。
  static Future<({encrypt.Key key, encrypt.IV iv})> _getMasterKey() async {
    final fromPlatform = await _readMasterKeyFromPlatform();
    if (fromPlatform != null) return fromPlatform;

    final fromFile = await _readMasterKeyFromFile();
    if (fromFile != null) {
      // Best-effort migrate file-backed key into platform storage.
      await _writeMasterKeyToPlatform(fromFile);
      return fromFile;
    }

    final rng = Random.secure();
    final keyBytes = Uint8List(32);
    final ivBytes = Uint8List(16);
    for (var i = 0; i < 32; i++) {
      keyBytes[i] = rng.nextInt(256);
    }
    for (var i = 0; i < 16; i++) {
      ivBytes[i] = rng.nextInt(256);
    }
    final generated = (
      key: encrypt.Key(keyBytes),
      iv: encrypt.IV(ivBytes),
    );

    final savedToPlatform = await _writeMasterKeyToPlatform(generated);
    if (!savedToPlatform) {
      await _writeMasterKeyToFile(generated);
    }
    return generated;
  }

  static Future<({encrypt.Key key, encrypt.IV iv})?> _readMasterKeyFromPlatform() async {
    try {
      final b64 = await _secureStorage.read(key: _masterKeyStorageKey);
      if (b64 == null || b64.isEmpty) return null;
      final bytes = base64Decode(b64);
      if (bytes.length < 48) return null;
      return (
        key: encrypt.Key(Uint8List.fromList(bytes.sublist(0, 32))),
        iv: encrypt.IV(Uint8List.fromList(bytes.sublist(32, 48))),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _writeMasterKeyToPlatform(
    ({encrypt.Key key, encrypt.IV iv}) master,
  ) async {
    try {
      final combined = Uint8List(48)
        ..setRange(0, 32, master.key.bytes)
        ..setRange(32, 48, master.iv.bytes);
      await _secureStorage.write(
        key: _masterKeyStorageKey,
        value: base64Encode(combined),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<({encrypt.Key key, encrypt.IV iv})?> _readMasterKeyFromFile() async {
    final dir = await _dir();
    final keyFile = File('${dir.path}/$_masterKeyFile');
    if (!keyFile.existsSync()) return null;
    final bytes = await keyFile.readAsBytes();
    if (bytes.length < 48) return null;
    return (
      key: encrypt.Key(bytes.sublist(0, 32)),
      iv: encrypt.IV(bytes.sublist(32, 48)),
    );
  }

  static Future<void> _writeMasterKeyToFile(
    ({encrypt.Key key, encrypt.IV iv}) master,
  ) async {
    final dir = await _dir();
    final keyFile = File('${dir.path}/$_masterKeyFile');
    final combined = Uint8List(48)
      ..setRange(0, 32, master.key.bytes)
      ..setRange(32, 48, master.iv.bytes);
    await keyFile.writeAsBytes(combined, flush: true);
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

  /// 模型 API Key 的存储键
  static String modelApiKeyStorageKey(String modelId) => 'model_api_key_$modelId';

  /// Provider 级 API Key 缓存键（按 apiBase）
  static String providerApiKeyStorageKey(String apiBase) =>
      'provider_api_key_$apiBase';

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
    try {
      await _secureStorage.delete(key: _masterKeyStorageKey);
    } catch (_) {}
  }
}

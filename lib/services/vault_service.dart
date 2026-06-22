import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'local_database_service.dart';
import 'logger_service.dart';

/// 历史数据保险库信息
class VaultInfo {
  final String vaultId;
  final DateTime createdAt;
  final int sizeBytes;

  VaultInfo({
    required this.vaultId,
    required this.createdAt,
    required this.sizeBytes,
  });

  String get displaySize {
    if (sizeBytes < 1024) return '${sizeBytes}B';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(1)}KB';
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  Map<String, dynamic> toJson() => {
    'vaultId': vaultId,
    'createdAt': createdAt.toIso8601String(),
    'sizeBytes': sizeBytes,
  };

  factory VaultInfo.fromJson(Map<String, dynamic> json) => VaultInfo(
    vaultId: json['vaultId'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    sizeBytes: json['sizeBytes'] as int,
  );
}

/// 密码保险库服务
///
/// 重置密码时，将所有 DB 文件加密打包成 vault 文件并保存。
/// 新密码从空白数据库开始，旧数据可通过旧密码解锁恢复。
///
/// ### vault 文件格式
/// ```
/// [4 bytes]  魔数: 0x53485056 ('SHPV')
/// [4 bytes]  版本: 0x01000000
/// [4 bytes]  元数据 JSON 长度（大端序）
/// [N bytes]  元数据 JSON（UTF-8）
/// [16 bytes] AES-256 IV（随机）
/// [M bytes]  AES-256-CBC 加密的 ZIP 字节流
/// [32 bytes] SHA-256 校验和（覆盖 IV + 密文）
/// ```
///
/// ### 加密密钥派生
/// `key = SHA-256(passwordHash + "_shepaw_vault_" + salt)`
///
class VaultService {
  static const String _vaultsDirName = 'shepaw_vaults';
  static const List<int> _magic = [0x53, 0x48, 0x50, 0x56]; // 'SHPV'
  static const List<int> _version = [0x01, 0x00, 0x00, 0x00];

  // 所有需要打包进 vault 的 DB 文件名
  static const List<String> _coreDbNames = [
    'shepaw.db',
    'she_profile.db',
    'she_memory.db',
    'minds.db',
  ];

  static final LoggerService _logger = LoggerService();

  // ---------------------------------------------------------------------------
  // 公共 API
  // ---------------------------------------------------------------------------

  /// 创建 vault：将所有 DB 文件加密打包
  ///
  /// - [passwordHash] 旧密码的 SHA-256 哈希（用于派生加密密钥）
  /// - [salt] 对应的盐值
  /// - 返回 vault 文件路径，失败时返回 null
  Future<String?> createVault({
    required String passwordHash,
    required String salt,
  }) async {
    if (kIsWeb) {
      _logger.warning('Vault not supported on Web platform', tag: 'Vault');
      return null;
    }

    try {
      final dbDir = await _getDbDirectory();
      final vaultsDir = await _getVaultsDirectory();

      // 收集需要打包的文件
      final filesToPack = <String, Uint8List>{};

      // 核心 DB 文件
      for (final name in _coreDbNames) {
        final file = File(p.join(dbDir, name));
        if (await file.exists()) {
          filesToPack[name] = await file.readAsBytes();
          _logger.info('Packing: $name (${filesToPack[name]!.length} bytes)', tag: 'Vault');
        }
      }

      // agent_memory_*.db 文件
      final dir = Directory(dbDir);
      await for (final entity in dir.list()) {
        if (entity is File) {
          final name = p.basename(entity.path);
          if (name.startsWith('agent_memory_') && name.endsWith('.db')) {
            filesToPack[name] = await entity.readAsBytes();
            _logger.info('Packing: $name (${filesToPack[name]!.length} bytes)', tag: 'Vault');
          }
        }
      }

      if (filesToPack.isEmpty) {
        _logger.warning('No DB files found to pack', tag: 'Vault');
        // 仍然创建空 vault 以记录历史
      }

      // 创建 ZIP
      final zipBytes = _createZip(filesToPack);

      // 派生加密密钥
      final encKey = _deriveEncryptionKey(passwordHash, salt);

      // 加密
      final iv = enc.IV.fromSecureRandom(16);
      final encrypter = enc.Encrypter(enc.AES(encKey, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encryptBytes(zipBytes, iv: iv);

      // 构建元数据
      final vaultId = 'vault_${DateTime.now().millisecondsSinceEpoch}';
      final meta = {
        'vaultId': vaultId,
        'createdAt': DateTime.now().toIso8601String(),
        'fileCount': filesToPack.length,
        'fileNames': filesToPack.keys.toList(),
        'salt': salt, // 存储 salt 以便恢复时使用
      };
      final metaBytes = utf8.encode(jsonEncode(meta));

      // 构建最终文件字节流
      final output = _buildVaultFile(
        metaBytes: metaBytes,
        iv: iv.bytes,
        cipherBytes: encrypted.bytes,
      );

      // 写入 vault 文件
      final vaultFile = File(p.join(vaultsDir, '$vaultId.shpv'));
      await vaultFile.writeAsBytes(output);

      _logger.info(
        'Vault created: ${vaultFile.path} (${output.length} bytes, ${filesToPack.length} DBs)',
        tag: 'Vault',
      );

      return vaultFile.path;
    } catch (e, st) {
      _logger.error('Failed to create vault', tag: 'Vault', error: e, stackTrace: st);
      return null;
    }
  }

  /// 获取所有历史 vault 列表（按时间倒序）
  Future<List<VaultInfo>> listVaults() async {
    if (kIsWeb) return [];

    try {
      final vaultsDir = await _getVaultsDirectory();
      final dir = Directory(vaultsDir);
      if (!await dir.exists()) return [];

      final vaults = <VaultInfo>[];
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.shpv')) {
          final stat = await entity.stat();
          final name = p.basenameWithoutExtension(entity.path);
          // vault_<timestamp>
          DateTime createdAt;
          try {
            final ts = int.parse(name.replaceFirst('vault_', ''));
            createdAt = DateTime.fromMillisecondsSinceEpoch(ts);
          } catch (_) {
            createdAt = stat.modified;
          }
          vaults.add(VaultInfo(
            vaultId: name,
            createdAt: createdAt,
            sizeBytes: stat.size,
          ));
        }
      }

      // 按时间倒序排列（最新的在前）
      vaults.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return vaults;
    } catch (e) {
      _logger.error('Failed to list vaults', tag: 'Vault', error: e);
      return [];
    }
  }

  /// 验证旧密码是否能解锁指定 vault
  ///
  /// - [vaultId] vault 文件名（不含扩展名）
  /// - [password] 用户输入的旧密码
  /// - [salt] 该密码对应的 salt（若存在于 vault 元数据中则自动提取）
  Future<bool> verifyVaultPassword({
    required String vaultId,
    required String password,
    required String salt,
  }) async {
    if (kIsWeb) return false;

    try {
      final vaultFile = await _getVaultFile(vaultId);
      if (!await vaultFile.exists()) return false;

      final vaultBytes = await vaultFile.readAsBytes();
      final parsed = _parseVaultFile(vaultBytes);

      // 从用户输入的密码派生 hash，再派生加密 key
      final passwordHash = _hashPassword(password, salt);
      final encKey = _deriveEncryptionKey(passwordHash, salt);

      // 验证校验和
      if (!_verifyChecksum(parsed)) return false;

      // 尝试解密（只解密前 16 字节以验证）
      try {
        final iv = enc.IV(Uint8List.fromList(parsed['iv'] as List<int>));
        final encrypter = enc.Encrypter(enc.AES(encKey, mode: enc.AESMode.cbc));
        encrypter.decryptBytes(
          enc.Encrypted(Uint8List.fromList(parsed['cipherBytes'] as List<int>)),
          iv: iv,
        );
        return true;
      } catch (_) {
        return false;
      }
    } catch (e) {
      _logger.error('Failed to verify vault password', tag: 'Vault', error: e);
      return false;
    }
  }

  /// 恢复 vault 到当前应用目录
  ///
  /// - [vaultId] vault 文件名（不含扩展名）
  /// - [password] 用户输入的旧密码
  /// - [salt] 该密码对应的 salt
  /// - 返回 true 表示成功，false 表示失败（密码错误或文件损坏）
  Future<bool> restoreVault({
    required String vaultId,
    required String password,
    required String salt,
  }) async {
    if (kIsWeb) return false;

    try {
      final vaultFile = await _getVaultFile(vaultId);
      if (!await vaultFile.exists()) {
        _logger.warning('Vault file not found: $vaultId', tag: 'Vault');
        return false;
      }

      final vaultBytes = await vaultFile.readAsBytes();
      final parsed = _parseVaultFile(vaultBytes);

      // 验证校验和
      if (!_verifyChecksum(parsed)) {
        _logger.warning('Vault checksum mismatch: $vaultId', tag: 'Vault');
        return false;
      }

      // 派生密钥
      final passwordHash = _hashPassword(password, salt);
      final encKey = _deriveEncryptionKey(passwordHash, salt);
      final iv = enc.IV(Uint8List.fromList(parsed['iv'] as List<int>));

      // 解密
      Uint8List zipBytes;
      try {
        final encrypter = enc.Encrypter(enc.AES(encKey, mode: enc.AESMode.cbc));
        final decrypted = encrypter.decryptBytes(
          enc.Encrypted(Uint8List.fromList(parsed['cipherBytes'] as List<int>)),
          iv: iv,
        );
        zipBytes = Uint8List.fromList(decrypted);
      } catch (e) {
        _logger.warning('Failed to decrypt vault (wrong password?): $e', tag: 'Vault');
        return false;
      }

      // 解压 ZIP
      final archive = ZipDecoder().decodeBytes(zipBytes);
      final dbDir = await _getDbDirectory();

      for (final file in archive) {
        if (file.isFile) {
          final outPath = p.join(dbDir, file.name);
          final outFile = File(outPath);
          await outFile.writeAsBytes(file.content as List<int>);
          _logger.info('Restored: ${file.name} (${file.size} bytes)', tag: 'Vault');
        }
      }

      _logger.info('Vault restored successfully: $vaultId', tag: 'Vault');
      return true;
    } catch (e, st) {
      _logger.error('Failed to restore vault', tag: 'Vault', error: e, stackTrace: st);
      return false;
    }
  }

  /// 删除指定 vault 文件
  Future<void> deleteVault(String vaultId) async {
    if (kIsWeb) return;

    try {
      final vaultFile = await _getVaultFile(vaultId);
      if (await vaultFile.exists()) {
        await vaultFile.delete();
        _logger.info('Vault deleted: $vaultId', tag: 'Vault');
      }
    } catch (e) {
      _logger.error('Failed to delete vault', tag: 'Vault', error: e);
    }
  }

  /// 从 vault 元数据中读取 salt（存储于创建时的元数据 JSON）
  ///
  /// 返回 null 表示该 vault 不含 salt 信息（旧版 vault）。
  Future<String?> getVaultSalt(String vaultId) async {
    if (kIsWeb) return null;

    try {
      final vaultFile = await _getVaultFile(vaultId);
      if (!await vaultFile.exists()) return null;

      final vaultBytes = await vaultFile.readAsBytes();
      final parsed = _parseVaultFile(vaultBytes);
      final meta = parsed['meta'] as Map<String, dynamic>;
      return meta['salt'] as String?;
    } catch (e) {
      _logger.error('Failed to read vault salt', tag: 'Vault', error: e);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 私有工具方法
  // ---------------------------------------------------------------------------

  /// 获取 DB 目录路径（与各 DB Service 保持一致，按当前账号 scope）
  Future<String> _getDbDirectory() async {
    final dir = await getApplicationDocumentsDirectory();
    final accountId = LocalDatabaseService().scopedAccountId;
    if (accountId != null && accountId.isNotEmpty) {
      final accountDir = Directory(p.join(dir.path, 'accounts', accountId));
      if (!await accountDir.exists()) {
        await accountDir.create(recursive: true);
      }
      return accountDir.path;
    }
    return dir.path;
  }

  /// 获取 vaults 存储目录（自动创建）
  Future<String> _getVaultsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final vaultsDir = Directory(p.join(appDir.path, _vaultsDirName));
    if (!await vaultsDir.exists()) {
      await vaultsDir.create(recursive: true);
    }
    return vaultsDir.path;
  }

  Future<File> _getVaultFile(String vaultId) async {
    final vaultsDir = await _getVaultsDirectory();
    return File(p.join(vaultsDir, '$vaultId.shpv'));
  }

  /// 将文件列表打包为 ZIP 字节
  List<int> _createZip(Map<String, Uint8List> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final archiveFile = ArchiveFile(
        entry.key,
        entry.value.length,
        entry.value,
      );
      archive.addFile(archiveFile);
    }
    return ZipEncoder().encode(archive)!;
  }

  /// 从 passwordHash 和 salt 派生 AES-256 密钥
  enc.Key _deriveEncryptionKey(String passwordHash, String salt) {
    final keyMaterial = utf8.encode('$passwordHash\_shepaw_vault_$salt');
    final keyHash = sha256.convert(keyMaterial);
    return enc.Key(Uint8List.fromList(keyHash.bytes));
  }

  /// SHA-256 哈希密码（与 PasswordService 保持相同逻辑）
  String _hashPassword(String password, String salt) {
    final bytes = utf8.encode(password + salt);
    return sha256.convert(bytes).toString();
  }

  /// 构建 vault 文件二进制内容
  List<int> _buildVaultFile({
    required List<int> metaBytes,
    required List<int> iv,
    required List<int> cipherBytes,
  }) {
    // 元数据长度（4 字节大端序）
    final metaLen = metaBytes.length;
    final metaLenBytes = [
      (metaLen >> 24) & 0xFF,
      (metaLen >> 16) & 0xFF,
      (metaLen >> 8) & 0xFF,
      metaLen & 0xFF,
    ];

    // 需要校验的内容（IV + 密文）
    final checksumInput = [...iv, ...cipherBytes];
    final checksum = sha256.convert(checksumInput).bytes;

    return [
      ..._magic,
      ..._version,
      ...metaLenBytes,
      ...metaBytes,
      ...iv,
      ...cipherBytes,
      ...checksum,
    ];
  }

  /// 解析 vault 文件为各组成部分
  Map<String, dynamic> _parseVaultFile(List<int> bytes) {
    var offset = 0;

    // 魔数（4 字节）
    offset += 4; // skip magic
    // 版本（4 字节）
    offset += 4; // skip version

    // 元数据长度（4 字节）
    final metaLen = (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
    offset += 4;

    // 元数据
    final metaBytes = bytes.sublist(offset, offset + metaLen);
    final meta = jsonDecode(utf8.decode(metaBytes)) as Map<String, dynamic>;
    offset += metaLen;

    // IV（16 字节）
    final iv = bytes.sublist(offset, offset + 16);
    offset += 16;

    // 密文（总长度 - offset - 32 校验和）
    final cipherEnd = bytes.length - 32;
    final cipherBytes = bytes.sublist(offset, cipherEnd);

    // 校验和（最后 32 字节）
    final storedChecksum = bytes.sublist(cipherEnd);

    return {
      'meta': meta,
      'iv': iv,
      'cipherBytes': cipherBytes,
      'storedChecksum': storedChecksum,
    };
  }

  /// 验证 vault 文件完整性
  bool _verifyChecksum(Map<String, dynamic> parsed) {
    try {
      final iv = parsed['iv'] as List<int>;
      final cipherBytes = parsed['cipherBytes'] as List<int>;
      final storedChecksum = parsed['storedChecksum'] as List<int>;

      final computed = sha256.convert([...iv, ...cipherBytes]).bytes;
      if (computed.length != storedChecksum.length) return false;

      for (var i = 0; i < computed.length; i++) {
        if (computed[i] != storedChecksum[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}

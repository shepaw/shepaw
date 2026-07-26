import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'snapshot_crypto.dart';

/// 快照 manifest（docs/storage_space_plan.md §5.2）。
class SnapshotManifest {
  SnapshotManifest({
    required this.deviceId,
    required this.createdAtMs,
    required this.appVersion,
    required this.schemaVersion,
    required this.dbSha256,
    required this.fileHashes,
    required this.treeRoot,
    this.attachments = const <String>[],
  });

  final String deviceId;
  final int createdAtMs;
  final String appVersion;

  /// 主库 schema 版本（恢复兼容性判断用）。
  final int schemaVersion;

  /// 明文 DB 的 SHA-256（解密后校验内容完整性）。
  final String dbSha256;

  /// 密文文件哈希：{'db.sqlite.enc': sha256, 'identity.enc': sha256}，
  /// 用于不输入密码即可发现传输/落盘损坏。
  final Map<String, String> fileHashes;

  /// 哈希树根：sha256(按文件名排序的 fileHash 拼接)。单点校验整个清单。
  final String treeRoot;

  /// 附件引用（M5 CAS 上线后填充；M1 快照只含 DB 与身份）。
  final List<String> attachments;

  static const fileDbEnc = 'db.sqlite.enc';
  static const fileIdentityEnc = 'identity.enc';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'device_id': deviceId,
        'created_at': createdAtMs,
        'app_version': appVersion,
        'schema_version': schemaVersion,
        'db_sha256': dbSha256,
        'files': fileHashes,
        'tree_root': treeRoot,
        'attachments': attachments,
      };

  static SnapshotManifest fromJson(Map<String, dynamic> json) {
    return SnapshotManifest(
      deviceId: json['device_id'] as String,
      createdAtMs: json['created_at'] as int,
      appVersion: json['app_version'] as String? ?? '',
      schemaVersion: json['schema_version'] as int? ?? 0,
      dbSha256: json['db_sha256'] as String,
      fileHashes: (json['files'] as Map).cast<String, String>(),
      treeRoot: json['tree_root'] as String,
      attachments:
          (json['attachments'] as List?)?.cast<String>() ?? const [],
    );
  }

  /// 计算清单树根（生成与校验共用同一算法）。
  static String computeTreeRoot(Map<String, String> fileHashes) {
    final sorted = fileHashes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final payload =
        sorted.map((e) => '${e.key}:${e.value}').join('\n');
    return crypto.sha256.convert(utf8.encode(payload)).toString();
  }
}

/// 一个本地快照的摘要信息（列表页用）。
class SnapshotInfo {
  SnapshotInfo({
    required this.id,
    required this.path,
    required this.manifest,
    required this.totalBytes,
  });

  /// 目录名（时间戳式 id，字典序 = 时间序）。
  final String id;
  final String path;
  final SnapshotManifest manifest;
  final int totalBytes;

  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(manifest.createdAtMs).toLocal();
}

/// 快照校验结果。
enum SnapshotVerifyStatus { ok, manifestTampered, fileTampered, unreadable }

/// 快照引擎（docs/storage_space_plan.md §5.2，M1）。
///
/// 目录布局：`<documents>/shepaw/store/<device_id>/backups/<ts>/`
/// - manifest.json / db.sqlite.enc / identity.enc
///
/// M1 范围说明：快照只含主库（shepaw.db）与设备身份；附件与其他辅助库
/// （she_memory/minds/agent_memory_*）待 M5 CAS 与后续里程碑纳入 manifest。
class SnapshotService {
  SnapshotService._();
  static final SnapshotService instance = SnapshotService._();

  static const _tag = 'Snapshot';
  static const _schemaVersion = 29; // 与 LocalDatabaseService version 保持一致

  final _log = LoggerService();

  /// 本机存储空间根目录（设备目录模型 §2）。
  Future<Directory> deviceStoreRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final deviceId = await DeviceIdentity.deviceId();
    final dir = Directory(p.join(docs.path, 'shepaw', 'store', deviceId));
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _backupsDir() async {
    final root = await deviceStoreRoot();
    final dir = Directory(p.join(root.path, 'backups'));
    await dir.create(recursive: true);
    return dir;
  }

  // ------------------------------------------------------------- 生成

  /// 生成快照：VACUUM INTO 一致性快照 → 加密 → 落 manifest。
  ///
  /// [password] 为 App 主密码（KDF 派生密钥，§5.2 离开本机前必须已加密）。
  /// 返回快照信息；失败抛异常。
  Future<SnapshotInfo> createSnapshot({required String password}) async {
    final key = await SnapshotCrypto.deriveKey(password);
    final backups = await _backupsDir();
    final now = DateTime.now().toUtc();
    final id = _snapshotId(now);
    final tmpDir = Directory(p.join(backups.path, '.$id.tmp'));
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    await tmpDir.create(recursive: true);
    try {
      // 1. 一致性快照（VACUUM INTO 无需停写）
      final db = await LocalDatabaseService().database;
      final rawFile = File(p.join(tmpDir.path, 'db.raw'));
      final escaped = rawFile.path.replaceAll("'", "''");
      await db.execute("VACUUM INTO '$escaped'");
      final rawBytes = await rawFile.readAsBytes();
      final dbSha256 = crypto.sha256.convert(rawBytes).toString();

      // 2. 加密 DB 与身份
      final dbEnc = await SnapshotCrypto.encrypt(rawBytes, key);
      final identityBytes = await DeviceIdentity.exportIdentity();
      final identityEnc = await SnapshotCrypto.encrypt(identityBytes, key);
      await rawFile.delete();

      final dbFile = File(p.join(tmpDir.path, SnapshotManifest.fileDbEnc));
      await dbFile.writeAsBytes(dbEnc, flush: true);
      final idFile =
          File(p.join(tmpDir.path, SnapshotManifest.fileIdentityEnc));
      await idFile.writeAsBytes(identityEnc, flush: true);

      // 3. manifest（密文哈希 + 树根 + 明文 DB 哈希）
      final fileHashes = <String, String>{
        SnapshotManifest.fileDbEnc: crypto.sha256.convert(dbEnc).toString(),
        SnapshotManifest.fileIdentityEnc:
            crypto.sha256.convert(identityEnc).toString(),
      };
      String appVersion = '';
      try {
        appVersion = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      final manifest = SnapshotManifest(
        deviceId: await DeviceIdentity.deviceId(),
        createdAtMs: now.millisecondsSinceEpoch,
        appVersion: appVersion,
        schemaVersion: _schemaVersion,
        dbSha256: dbSha256,
        fileHashes: fileHashes,
        treeRoot: SnapshotManifest.computeTreeRoot(fileHashes),
      );
      final manifestFile = File(p.join(tmpDir.path, 'manifest.json'));
      await manifestFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(manifest.toJson()),
          flush: true);

      // 4. 原子转正（rename 同卷原子）
      final finalDir = Directory(p.join(backups.path, id));
      if (await finalDir.exists()) await finalDir.delete(recursive: true);
      await tmpDir.rename(finalDir.path);

      final info = SnapshotInfo(
        id: id,
        path: finalDir.path,
        manifest: manifest,
        totalBytes: dbEnc.length + identityEnc.length,
      );
      _log.info('snapshot created: $id (${info.totalBytes} bytes)', tag: _tag);
      return info;
    } catch (e, st) {
      _log.error('snapshot creation failed', tag: _tag, error: e, stackTrace: st);
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
      rethrow;
    }
  }

  // ------------------------------------------------------------- 列表/读取

  /// 列出本机全部快照（新→旧）。
  Future<List<SnapshotInfo>> listSnapshots() async {
    final backups = await _backupsDir();
    final result = <SnapshotInfo>[];
    await for (final entry in backups.list()) {
      if (entry is! Directory) continue;
      final id = p.basename(entry.path);
      if (id.startsWith('.')) continue; // .tmp / 隐藏目录
      final manifestFile = File(p.join(entry.path, 'manifest.json'));
      if (!await manifestFile.exists()) continue;
      try {
        final manifest = SnapshotManifest.fromJson(
            jsonDecode(await manifestFile.readAsString())
                as Map<String, dynamic>);
        var total = 0;
        await for (final f in entry.list(recursive: true)) {
          if (f is File) total += await f.length();
        }
        result.add(SnapshotInfo(
            id: id, path: entry.path, manifest: manifest, totalBytes: total));
      } catch (e) {
        _log.warning('unreadable snapshot $id: $e', tag: _tag);
      }
    }
    result.sort((a, b) => b.id.compareTo(a.id));
    return result;
  }

  /// 读取并解密 DB（恢复前必须先经 [verifySnapshot] 与密码校验）。
  Future<Uint8List> decryptDb(SnapshotInfo info, String password) async {
    final key = await SnapshotCrypto.deriveKey(password);
    final packed = await File(p.join(info.path, SnapshotManifest.fileDbEnc))
        .readAsBytes();
    final plain = await SnapshotCrypto.decrypt(packed, key);
    // 内容级校验：解密成功但明文哈希不符 = manifest 被换过
    if (crypto.sha256.convert(plain).toString() != info.manifest.dbSha256) {
      throw StateError('db content hash mismatch after decrypt');
    }
    return plain;
  }

  /// 解密身份记录。
  Future<Uint8List> decryptIdentity(SnapshotInfo info, String password) async {
    final key = await SnapshotCrypto.deriveKey(password);
    final packed =
        await File(p.join(info.path, SnapshotManifest.fileIdentityEnc))
            .readAsBytes();
    return SnapshotCrypto.decrypt(packed, key);
  }

  // ------------------------------------------------------------- 校验

  /// 免密码校验：重读磁盘 manifest → 树根自洽 → 各密文文件哈希一致。
  /// 可发现落盘/传输损坏与 manifest 替换；内容级校验在解密时进行。
  Future<SnapshotVerifyStatus> verifySnapshot(SnapshotInfo info) async {
    try {
      // 以磁盘 manifest 为准（info 可能是内存旧值）
      final manifestFile = File(p.join(info.path, 'manifest.json'));
      if (!await manifestFile.exists()) {
        return SnapshotVerifyStatus.unreadable;
      }
      final manifest = SnapshotManifest.fromJson(
          jsonDecode(await manifestFile.readAsString())
              as Map<String, dynamic>);
      // 树根自洽
      final expected =
          SnapshotManifest.computeTreeRoot(manifest.fileHashes);
      if (expected != manifest.treeRoot) {
        return SnapshotVerifyStatus.manifestTampered;
      }
      // 各文件哈希一致
      for (final entry in manifest.fileHashes.entries) {
        final f = File(p.join(info.path, entry.key));
        if (!await f.exists()) return SnapshotVerifyStatus.fileTampered;
        final digest = await crypto.sha256.bind(f.openRead()).first;
        if (digest.toString() != entry.value) {
          return SnapshotVerifyStatus.fileTampered;
        }
      }
      return SnapshotVerifyStatus.ok;
    } catch (e) {
      _log.warning('verify ${info.id} failed: $e', tag: _tag);
      return SnapshotVerifyStatus.unreadable;
    }
  }

  // ------------------------------------------------------------- 本机导出

  /// 本机导出（§5.1 决策 3：纯手动路径）：把快照目录整体复制到 [targetDir]。
  /// 返回导出目标目录。
  Future<Directory> exportToDirectory(
      SnapshotInfo info, String targetDir) async {
    final target = Directory(p.join(targetDir, info.id));
    if (await target.exists()) await target.delete(recursive: true);
    await target.create(recursive: true);
    final source = Directory(info.path);
    await for (final f in source.list(recursive: true)) {
      if (f is File) {
        final rel = p.relative(f.path, from: source.path);
        final dest = File(p.join(target.path, rel));
        await dest.parent.create(recursive: true);
        await f.copy(dest.path);
      }
    }
    _log.info('snapshot ${info.id} exported to ${target.path}', tag: _tag);
    return target;
  }

  // ------------------------------------------------------------- 工具

  static String _snapshotId(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }
}

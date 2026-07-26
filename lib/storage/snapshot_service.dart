import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
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
    this.kdfSalt,
    this.kdfIterations,
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

  /// KDF 快照盐（base64，M3 起；null = M1 旧格式，用设备 salt，
  /// 仅本机可解——换机导入要求 v2 格式）。
  final String? kdfSalt;

  /// KDF 迭代数（记录用，当前恒 120000）。
  final int? kdfIterations;

  /// 附件引用（M5 CAS 上线后填充；M1/M3 快照只含 DB 与身份）。
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
        if (kdfSalt != null) 'kdf_salt': kdfSalt,
        if (kdfIterations != null) 'kdf_iterations': kdfIterations,
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
      kdfSalt: json['kdf_salt'] as String?,
      kdfIterations: json['kdf_iterations'] as int?,
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

/// 本机导出结果（§5.1：快照目录 + manifest 引用的附件）。
class SnapshotExportResult {
  SnapshotExportResult({
    required this.directory,
    required this.packedAttachments,
    required this.missingAttachments,
  });

  final Directory directory;

  /// 成功打包的附件数。
  final int packedAttachments;

  /// manifest 中有、本机找不到的 hash 路径。
  final List<String> missingAttachments;
}

/// 快照引擎（docs/storage_space_plan.md §5.2，M1）。
///
/// 目录布局：`<documents>/shepaw/store/<device_id>/backups/<ts>/`
/// - manifest.json / db.sqlite.enc / identity.enc
///
/// M1 范围说明：快照目录只含主库与设备身份；附件按 hash 列入 manifest，
/// 手动导出时一并打包（§5.1 / §5.2）。
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

  /// 生成快照：VACUUM INTO 一致性快照 → 加密 → 经 LocalStore write/commit 落盘。
  ///
  /// 密钥来源二选一：[password]（慢路径）或 [passwordHash]（快路径，
  /// 定期快照用缓存的 H）。[cachePassword] 为 true 且走 password 慢路径时，
  /// 顺带刷新自动快照缓存；恢复安全快照等场景应传 false，避免旧密码污染缓存。
  /// 离开本机前必须已加密（§5.2）；最终三文件经 store staging 转正（§5.1/§6.1）。
  /// 失败抛异常。
  Future<SnapshotInfo> createSnapshot(
      {String? password,
      Uint8List? passwordHash,
      bool cachePassword = true}) async {
    final h = passwordHash ??
        (password != null
            ? await SnapshotCrypto.hashPassword(password)
            : throw ArgumentError('password or passwordHash required'));
    if (password != null && cachePassword) {
      // 验密成功顺带刷新自动快照的缓存密钥
      await SnapshotCrypto.cachePasswordHash(h);
    }
    final snapshotSalt = SnapshotCrypto.newSnapshotSalt();
    final key = await SnapshotCrypto.deriveKeyFromHash(h, snapshotSalt);
    final backups = await _backupsDir();
    final now = DateTime.now().toUtc();
    final id = _snapshotId(now);
    // 明文 VACUUM 与加密产物暂存系统临时目录，不进 backups/（半成品不可见）
    final workDir = await Directory.systemTemp.createTemp('shepaw_snap_');
    try {
      // 1. 一致性快照（VACUUM INTO 无需停写）
      final db = await LocalDatabaseService().database;
      final rawFile = File(p.join(workDir.path, 'db.raw'));
      final escaped = rawFile.path.replaceAll("'", "''");
      await db.execute("VACUUM INTO '$escaped'");
      final rawBytes = await rawFile.readAsBytes();
      final dbSha256 = crypto.sha256.convert(rawBytes).toString();

      // 2. 加密 DB 与身份
      final dbEnc = await SnapshotCrypto.encrypt(rawBytes, key);
      final identityBytes = await DeviceIdentity.exportIdentity();
      final identityEnc = await SnapshotCrypto.encrypt(identityBytes, key);
      await rawFile.delete();

      // 3. manifest（密文哈希 + 树根 + 明文 DB 哈希 + KDF 参数）
      final fileHashes = <String, String>{
        SnapshotManifest.fileDbEnc: crypto.sha256.convert(dbEnc).toString(),
        SnapshotManifest.fileIdentityEnc:
            crypto.sha256.convert(identityEnc).toString(),
      };
      String appVersion = '';
      try {
        appVersion = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      final deviceId = await DeviceIdentity.deviceId();
      final manifest = SnapshotManifest(
        deviceId: deviceId,
        createdAtMs: now.millisecondsSinceEpoch,
        appVersion: appVersion,
        schemaVersion: _schemaVersion,
        dbSha256: dbSha256,
        fileHashes: fileHashes,
        treeRoot: SnapshotManifest.computeTreeRoot(fileHashes),
        kdfSalt: base64.encode(snapshotSalt),
        kdfIterations: 120000,
        attachments: await _listAttachmentHashes(deviceId),
      );
      final manifestBytes = Uint8List.fromList(utf8.encode(
          const JsonEncoder.withIndent('  ').convert(manifest.toJson())));

      // 4. 经 LocalStore write.begin/chunk/commit 原子转正；撞名加序号
      var finalId = id;
      var suffix = 2;
      while (await Directory(p.join(backups.path, finalId)).exists()) {
        finalId = '$id-$suffix';
        suffix++;
      }
      await _commitSnapshotFiles(
        deviceId: deviceId,
        snapshotId: finalId,
        files: {
          SnapshotManifest.fileDbEnc: dbEnc,
          SnapshotManifest.fileIdentityEnc: identityEnc,
          'manifest.json': manifestBytes,
        },
      );

      final finalDir = Directory(p.join(backups.path, finalId));
      final info = SnapshotInfo(
        id: finalId,
        path: finalDir.path,
        manifest: manifest,
        totalBytes: dbEnc.length + identityEnc.length,
      );
      _log.info('snapshot created: $finalId (${info.totalBytes} bytes)',
          tag: _tag);
      return info;
    } catch (e, st) {
      _log.error('snapshot creation failed',
          tag: _tag, error: e, stackTrace: st);
      rethrow;
    } finally {
      if (await workDir.exists()) {
        try {
          await workDir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// 与 [StoreService] 同根的 LocalStore（本机 loopback 写路径）。
  Future<LocalStore> _openLocalStore() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'shepaw', 'store'));
    await root.create(recursive: true);
    return LocalStore(root: root);
  }

  /// 把快照三文件经 staging 写入 backups，一批 commit；失败则回滚已转正项。
  Future<void> _commitSnapshotFiles({
    required String deviceId,
    required String snapshotId,
    required Map<String, Uint8List> files,
  }) async {
    final store = await _openLocalStore();
    const space = 'backups';
    final uploadIds = <String>[];
    for (final entry in files.entries) {
      final rel = '$snapshotId/${entry.key}';
      final bytes = entry.value;
      final sha = crypto.sha256.convert(bytes).toString();
      final (uid, _) = await store.writeBegin(
        deviceId: deviceId,
        space: space,
        path: rel,
        size: bytes.length,
        sha256: sha,
      );
      var offset = 0;
      while (offset < bytes.length) {
        final end = min(offset + LocalStore.maxReadChunk, bytes.length);
        await store.writeChunk(
            deviceId, space, uid, offset, bytes.sublist(offset, end));
        offset = end;
      }
      uploadIds.add(uid);
    }
    final (committed, failed) = await store.commit(deviceId, space, uploadIds);
    if (failed.isNotEmpty) {
      for (final f in committed) {
        try {
          await store.delete(deviceId, space, f.path);
        } catch (_) {}
      }
      throw StateError('snapshot store commit failed: $failed');
    }
  }

  /// 附件 hash 清单（§5.2：附件不进快照，按 hash 引用；M5 起附件
  /// 编址即 hash，文件名即 hash 值）。
  Future<List<String>> _listAttachmentHashes(String deviceId) async {
    try {
      final root = await deviceStoreRoot();
      final dir = Directory(p.join(root.path, 'attachments'));
      if (!await dir.exists()) return const [];
      final hashes = <String>[];
      await for (final f in dir.list(recursive: true)) {
        if (f is! File) continue;
        final rel = p.relative(f.path, from: dir.path);
        if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
        hashes.add(rel.replaceAll(p.separator, '/'));
      }
      return hashes;
    } catch (_) {
      return const [];
    }
  }

  // ------------------------------------------------------------- 列表/读取

  /// 列出本机 DB 快照（新→旧）。跳过镜像再保护包（`reprotect-*` /
  /// `kind: mirror_reprotect`），避免误入恢复列表与 GFS。
  Future<List<SnapshotInfo>> listSnapshots() async {
    final backups = await _backupsDir();
    final result = <SnapshotInfo>[];
    await for (final entry in backups.list()) {
      if (entry is! Directory) continue;
      final id = p.basename(entry.path);
      if (id.startsWith('.')) continue; // .tmp / 隐藏目录
      if (id.startsWith('reprotect-')) continue;
      final manifestFile = File(p.join(entry.path, 'manifest.json'));
      if (!await manifestFile.exists()) continue;
      try {
        final json = jsonDecode(await manifestFile.readAsString())
            as Map<String, dynamic>;
        if (json['kind'] == 'mirror_reprotect') continue;
        final manifest = SnapshotManifest.fromJson(json);
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

  /// 解密用密钥：v2 manifest（含 kdf_salt）用两级 KDF；M1 旧格式回退
  /// 设备 salt（仅本机可解）。
  Future<SecretKey> _keyFor(
    SnapshotInfo info, {
    String? password,
    Uint8List? passwordHash,
  }) async {
    final saltB64 = info.manifest.kdfSalt;
    if (saltB64 == null) {
      if (password == null) {
        throw ArgumentError('legacy snapshot requires password');
      }
      return SnapshotCrypto.deriveLegacyKey(password);
    }
    final h = passwordHash ??
        (password != null
            ? await SnapshotCrypto.hashPassword(password)
            : throw ArgumentError('password or passwordHash required'));
    return SnapshotCrypto.deriveKeyFromHash(
        h, Uint8List.fromList(base64.decode(saltB64)));
  }

  /// 读取并解密 DB（恢复前必须先经 [verifySnapshot] 与密码校验）。
  Future<Uint8List> decryptDb(SnapshotInfo info, String password) async {
    final key = await _keyFor(info, password: password);
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
    final key = await _keyFor(info, password: password);
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

  /// 本机导出（§5.1 决策 3：纯手动路径）：复制快照三文件，并按 manifest
  /// 打包本机 `<device_id>/attachments/` 中引用的附件（§5.2）。
  Future<SnapshotExportResult> exportToDirectory(
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

    final missing = <String>[];
    var packed = 0;
    final hashes = info.manifest.attachments;
    if (hashes.isNotEmpty) {
      final deviceRoot = await deviceStoreRoot();
      final attachRoot = Directory(p.join(deviceRoot.path, 'attachments'));
      for (final hash in hashes) {
        if (hash.isEmpty || hash.contains('..')) {
          missing.add(hash);
          continue;
        }
        final src = File(p.join(attachRoot.path, hash));
        if (!await src.exists()) {
          missing.add(hash);
          continue;
        }
        final dest = File(p.join(target.path, 'attachments', hash));
        await dest.parent.create(recursive: true);
        await src.copy(dest.path);
        packed++;
      }
    }

    _log.info(
        'snapshot ${info.id} exported to ${target.path} '
        '(attachments packed=$packed missing=${missing.length})',
        tag: _tag);
    return SnapshotExportResult(
      directory: target,
      packedAttachments: packed,
      missingAttachments: missing,
    );
  }

  // ------------------------------------------------------------- 工具

  static String _snapshotId(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}-'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}';
  }
}

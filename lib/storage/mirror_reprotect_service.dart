import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'snapshot_crypto.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// master 镜像树再保护（docs/storage_space_plan.md §6.6，M6）。
///
/// 将 store 根下各 `<device_id>/<space>/`（跳过 .staging / .system / .recycle）
/// 打成 tar → 主密码派生密钥加密 → 经 LocalStore commit 写入
/// `<master_id>/backups/reprotect-<ts>/`。
class MirrorReprotectService {
  MirrorReprotectService._();
  static final MirrorReprotectService instance = MirrorReprotectService._();

  static const _tag = 'MirrorReprotect';
  final _log = LoggerService();

  /// 仅 master 本机执行；无缓存密钥时跳过。
  Future<String?> runIfMaster() async {
    if (!await StoreService.instance.isMaster()) return null;
    final h = await SnapshotCrypto.cachedPasswordHash();
    if (h == null) {
      _log.info('skip reprotect: no cached password hash', tag: _tag);
      return null;
    }
    return run(passwordHash: h);
  }

  Future<String> run({required Uint8List passwordHash}) async {
    final store = await StoreService.instance.localStore();
    final self = await DeviceIdentity.deviceId();
    final now = DateTime.now().toUtc();
    final id =
        'reprotect-${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';

    final workDir = await Directory.systemTemp.createTemp('shepaw_reprotect_');
    try {
      final archive = Archive();
      var fileCount = 0;
      await for (final entity in store.root.list()) {
        if (entity is! Directory) continue;
        final deviceId = p.basename(entity.path);
        if (!isValidDeviceId(deviceId)) continue;
        for (final space in StoreSpace.all) {
          final spaceDir = Directory(p.join(entity.path, space));
          if (!await spaceDir.exists()) continue;
          await for (final f in spaceDir.list(recursive: true)) {
            if (f is! File) continue;
            final rel = p.relative(f.path, from: spaceDir.path);
            if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
            final bytes = await f.readAsBytes();
            final entryName = '$deviceId/$space/${rel.replaceAll(r'\', '/')}';
            archive.addFile(ArchiveFile(entryName, bytes.length, bytes));
            fileCount++;
          }
        }
      }

      final tarBytes = Uint8List.fromList(TarEncoder().encode(archive));
      final salt = SnapshotCrypto.newSnapshotSalt();
      final key = await SnapshotCrypto.deriveKeyFromHash(passwordHash, salt);
      final enc = await SnapshotCrypto.encrypt(tarBytes, key);

      final manifest = <String, dynamic>{
        'kind': 'mirror_reprotect',
        'created_at': now.millisecondsSinceEpoch,
        'master_device': self,
        'file_count': fileCount,
        'plain_sha256': crypto.sha256.convert(tarBytes).toString(),
        'enc_sha256': crypto.sha256.convert(enc).toString(),
        'kdf_salt': base64.encode(salt),
        'kdf_iterations': 120000,
      };
      final manifestBytes = Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(manifest)));

      await _commitFiles(store, self, id, {
        'manifest.json': manifestBytes,
        'mirror.tar.enc': enc,
      });

      _log.info('reprotect $id ($fileCount files, ${enc.length} enc bytes)',
          tag: _tag);
      return id;
    } finally {
      try {
        if (await workDir.exists()) await workDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _commitFiles(
    LocalStore store,
    String deviceId,
    String snapshotId,
    Map<String, Uint8List> files,
  ) async {
    const space = 'backups';
    final uploadIds = <String>[];
    for (final e in files.entries) {
      final rel = '$snapshotId/${e.key}';
      final sha = crypto.sha256.convert(e.value).toString();
      final (uid, _) = await store.writeBegin(
        deviceId: deviceId,
        space: space,
        path: rel,
        size: e.value.length,
        sha256: sha,
      );
      var offset = 0;
      while (offset < e.value.length) {
        final end = min(offset + LocalStore.maxReadChunk, e.value.length);
        await store.writeChunk(
            deviceId, space, uid, offset, e.value.sublist(offset, end));
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
      throw StateError('reprotect commit failed: $failed');
    }
  }
}

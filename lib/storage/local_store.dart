import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'store_protocol.dart';
import 'sync_journal.dart';

/// store 层错误（StoreService 转为 error 帧）。
class StoreException implements Exception {
  StoreException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'StoreException($code): $message';
}

/// list/meta 返回的文件条目。
class StoreEntry {
  StoreEntry({
    required this.path,
    required this.size,
    required this.sha256,
    required this.mtimeMs,
  });

  final String path;
  final int size;
  final String sha256;
  final int mtimeMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'size': size,
        'sha256': sha256,
        'mtime': mtimeMs,
      };
}

/// 回收站条目（spec §2.8）。
class RecycleEntry {
  RecycleEntry({
    required this.recyclePath,
    required this.originDevice,
    required this.space,
    required this.originPath,
    required this.size,
    required this.deletedAtMs,
  });

  final String recyclePath;
  final String originDevice;
  final String space;
  final String originPath;
  final int size;
  final int deletedAtMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'recycle_path': recyclePath,
        'origin_device': originDevice,
        'space': space,
        'origin_path': originPath,
        'size': size,
        'deleted_at': deletedAtMs,
      };
}

/// 暂存会话元数据（.staging/<upload_id>.json）。
class _StagingMeta {
  _StagingMeta({
    required this.path,
    required this.size,
    required this.sha256,
    required this.createdMs,
  });

  final String path;
  final int size;
  final String sha256;
  final int createdMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'size': size,
        'sha256': sha256,
        'created_ms': createdMs,
      };

  static _StagingMeta fromJson(Map<String, dynamic> json) => _StagingMeta(
        path: json['path'] as String,
        size: json['size'] as int,
        sha256: json['sha256'] as String,
        createdMs: json['created_ms'] as int,
      );
}

/// 设备目录文件系统实现（docs/storage_protocol_spec.md）。
///
/// 布局（store root 下）：
/// ```
/// <device_id>/<space>/...            正式区
/// <device_id>/<space>/.staging/      未 commit 半成品（list/meta 不可见）
/// .recycle/<yyyy-MM-dd>/<device_id>/<space>/...  回收站
/// ```
class LocalStore {
  LocalStore({required this.root});

  /// store 根目录（…/shepaw/store）。
  final Directory root;

  static const _uuid = Uuid();
  static const maxReadChunk = 64 * 1024;

  /// 变更日志挂接点（docs/storage_protocol_spec.md §6.1）。
  /// 由 SyncEngine.start 设置；commit/delete 成功路径内联调用，
  /// 保证"落盘成功即入队"无窗口期。
  static SyncJournal? syncJournal;

  /// sha256 内存缓存：path → (mtime, size, hash)。
  final Map<String, (int, int, String)> _hashCache = {};

  // ────────────────────────────── 路径解析（防逃逸，spec §4）──

  Directory _deviceDir(String deviceId) {
    if (!isValidDeviceId(deviceId)) {
      throw StoreException(StoreError.badOp, 'invalid device_id');
    }
    return Directory(p.join(root.path, deviceId));
  }

  String _spaceDir(String deviceId, String space) {
    if (!StoreSpace.isValid(space)) {
      throw StoreException(StoreError.badOp, 'invalid space');
    }
    return p.join(_deviceDir(deviceId).path, space);
  }

  /// 把 space 内相对路径解析为绝对路径并做前缀校验。
  /// 文件已存在时再做符号链接逃逸校验。
  String _resolveInSpace(String deviceId, String space, String relPath) {
    final normalized = normalizeStorePath(relPath);
    final base = p.normalize(_spaceDir(deviceId, space));
    final abs = p.normalize(p.join(base, normalized));
    if (!p.isWithin(base, abs)) {
      throw StoreException(StoreError.badPath, 'escapes device dir');
    }
    return abs;
  }

  /// 已存在实体的符号链接校验（防 symlink 逃逸）。
  Future<void> _checkNoSymlinkEscape(String deviceId, String space,
      String absPath, String normalizedRel) async {
    final base = p.normalize(_spaceDir(deviceId, space));
    if (await FileSystemEntity.type(absPath, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StoreException(StoreError.badPath, 'symlink not allowed');
    }
    if (await FileSystemEntity.isLink(absPath)) {
      throw StoreException(StoreError.badPath, 'symlink not allowed');
    }
    // 逐段检查（父目录也可能是链接）
    final rel = p.relative(absPath, from: base);
    var cursor = base;
    for (final seg in p.split(rel)) {
      cursor = p.join(cursor, seg);
      if (await FileSystemEntity.isLink(cursor)) {
        throw StoreException(StoreError.badPath, 'symlink not allowed');
      }
    }
  }

  String _stagingDir(String deviceId, String space) =>
      p.join(_spaceDir(deviceId, space), '.staging');

  // ────────────────────────────── list / meta / read ──

  /// 递归列出 space 下文件（跳过 .staging 与一切 . 开头目录）。
  Future<List<StoreEntry>> list(
    String deviceId,
    String space, {
    String? prefix,
    int limit = 1000,
  }) async {
    final baseAbs = _spaceDir(deviceId, space);
    final base = Directory(baseAbs);
    if (!await base.exists()) return const [];
    final entries = <StoreEntry>[];
    await for (final entity in base.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: baseAbs);
      if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
      if (prefix != null && !rel.startsWith(prefix)) continue;
      final stat = await entity.stat();
      entries.add(StoreEntry(
        path: rel.replaceAll(p.separator, '/'),
        size: stat.size,
        sha256: await _hashOf(entity, stat),
        mtimeMs: stat.modified.millisecondsSinceEpoch,
      ));
      if (entries.length >= limit) break;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    return entries;
  }

  /// meta：文件 → 单条元数据；目录 → 清单（spec §2.2）。
  Future<Map<String, dynamic>> meta(
      String deviceId, String space, String relPath) async {
    final abs = _resolveInSpace(deviceId, space, relPath);
    final baseAbs = _spaceDir(deviceId, space);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw StoreException(StoreError.notFound, relPath);
    }
    await _checkNoSymlinkEscape(deviceId, space, abs, relPath);
    if (type == FileSystemEntityType.file) {
      final f = File(abs);
      final stat = await f.stat();
      return <String, dynamic>{
        'kind': 'file',
        'size': stat.size,
        'sha256': await _hashOf(f, stat),
        'mtime': stat.modified.millisecondsSinceEpoch,
      };
    }
    // 目录：清单（相对目录自身的子路径）
    final normalized = normalizeStorePath(relPath);
    final files = await list(deviceId, space,
        prefix: normalized.endsWith('/') ? normalized : '$normalized/');
    return <String, dynamic>{
      'kind': 'dir',
      'files': [
        for (final e in files)
          <String, dynamic>{
            'path': e.path,
            'sha256': e.sha256,
            'size': e.size,
            'mtime': e.mtimeMs,
          },
      ],
    };
  }

  /// 读文件块（≤64KB，spec §2.3）。
  Future<(Uint8List, int, bool)> read(String deviceId, String space,
      String relPath, int offset, int length) async {
    if (length <= 0 || length > maxReadChunk) {
      throw StoreException(
          StoreError.badOp, 'length must be 1..$maxReadChunk');
    }
    if (offset < 0) throw StoreException(StoreError.badOp, 'negative offset');
    final abs = _resolveInSpace(deviceId, space, relPath);
    final f = File(abs);
    if (!await f.exists()) throw StoreException(StoreError.notFound, relPath);
    await _checkNoSymlinkEscape(deviceId, space, abs, relPath);
    final size = await f.length();
    if (offset >= size) return (Uint8List(0), size, true);
    final raf = await f.open();
    try {
      await raf.setPosition(offset);
      final data = await raf.read(length);
      return (data, size, offset + data.length >= size);
    } finally {
      await raf.close();
    }
  }

  // ────────────────────────────── write.begin / write.chunk / commit ──

  /// 开始（或续传）一次写入，返回 (upload_id, 已接收字节数)。
  Future<(String, int)> writeBegin({
    required String deviceId,
    required String space,
    required String path,
    required int size,
    required String sha256,
    String? uploadId,
  }) async {
    if (size < 0) throw StoreException(StoreError.badOp, 'negative size');
    final normalized = normalizeStorePath(path);
    _resolveInSpace(deviceId, space, normalized); // 仅校验
    final stagingDir = Directory(_stagingDir(deviceId, space));
    await stagingDir.create(recursive: true);

    final id = uploadId ?? 'u-${_uuid.v4()}';
    final partFile = File(p.join(stagingDir.path, '$id.part'));
    final metaFile = File(p.join(stagingDir.path, '$id.json'));

    if (await metaFile.exists()) {
      // 续传：元数据一致才允许（否则视为新会话冲突）
      final meta = _StagingMeta.fromJson(
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>);
      if (meta.path != normalized ||
          meta.size != size ||
          meta.sha256 != sha256) {
        throw StoreException(
            StoreError.stagingState, 'upload_id conflicts with existing');
      }
      final received =
          await partFile.exists() ? await partFile.length() : 0;
      return (id, received);
    }

    final meta = _StagingMeta(
        path: normalized,
        size: size,
        sha256: sha256,
        createdMs: DateTime.now().millisecondsSinceEpoch);
    await metaFile.writeAsString(jsonEncode(meta.toJson()));
    return (id, 0);
  }

  /// 写数据块（offset ≤ 已接收长度，顺序追加；spec §2.5；单块 ≤64KB）。
  Future<int> writeChunk(String deviceId, String space, String uploadId,
      int offset, Uint8List data) async {
    if (data.length > maxReadChunk) {
      throw StoreException(
          StoreError.badOp, 'chunk must be ≤$maxReadChunk bytes');
    }
    final stagingDir = _stagingDir(deviceId, space);
    final metaFile = File(p.join(stagingDir, '$uploadId.json'));
    if (!await metaFile.exists()) {
      throw StoreException(StoreError.stagingState, 'unknown upload_id');
    }
    final partFile = File(p.join(stagingDir, '$uploadId.part'));
    final current = await partFile.exists() ? await partFile.length() : 0;
    if (offset > current) {
      throw StoreException(
          StoreError.stagingState, 'offset $offset beyond received $current');
    }
    // FileMode.append：不存在则创建、不清空、setPosition 随机写。
    // （FileMode.write 打开即截断，会毁掉断点续传。）
    final raf = await partFile.open(mode: FileMode.append);
    try {
      await raf.setPosition(offset);
      await raf.writeFrom(data);
    } finally {
      await raf.close();
    }
    return offset + data.length > current ? offset + data.length : current;
  }

  /// 原子转正（spec §2.6）：先全量验哈希（任一失败整批不转正），
  /// 再逐个 rename；目标已存在时旧版本先进回收站。
  /// 成功后经 [syncJournal] 内联记日志（本机设备目录变更入未同步队列）。
  /// 返回（已转正文件清单，失败项）。
  Future<(List<({String path, int size, String sha256})>, List<String>)>
      commit(String deviceId, String space, List<String> uploadIds) async {
    final stagingDir = _stagingDir(deviceId, space);
    final verified = <(String, _StagingMeta, File)>[];
    final failed = <String>[];

    // 阶段一：全量校验（spec §2.6：全部通过才进入转正）
    for (final id in uploadIds) {
      final metaFile = File(p.join(stagingDir, '$id.json'));
      if (!await metaFile.exists()) {
        failed.add('$id: unknown upload_id');
        continue;
      }
      final meta = _StagingMeta.fromJson(
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>);
      final partFile = File(p.join(stagingDir, '$id.part'));
      final length = await partFile.exists() ? await partFile.length() : 0;
      if (length != meta.size) {
        failed.add('$id: size $length != declared ${meta.size}');
        continue;
      }
      final digest = await crypto.sha256.bind(partFile.openRead()).first;
      if (digest.toString() != meta.sha256) {
        failed.add('$id: hash mismatch');
        continue;
      }
      verified.add((id, meta, partFile));
    }
    if (failed.isNotEmpty) {
      return (
        const <({String path, int size, String sha256})>[],
        failed
      );
    }

    // 阶段二：逐个转正（同卷 rename 原子；单文件失败其余继续）
    final committed = <({String path, int size, String sha256})>[];
    for (final (id, meta, partFile) in verified) {
      try {
        final finalAbs = _resolveInSpace(deviceId, space, meta.path);
        // 转正前检查目标路径（含父目录）无 symlink 逃逸
        await _checkNoSymlinkEscape(deviceId, space, finalAbs, meta.path);
        if (await File(finalAbs).exists()) {
          // 被覆盖旧版本进回收站（spec §6.2）
          await _moveToRecycle(deviceId, space, meta.path);
        }
        await File(finalAbs).parent.create(recursive: true);
        await partFile.rename(finalAbs);
        _hashCache.remove(finalAbs);
        await File(p.join(stagingDir, '$id.json')).delete();
        committed.add(
            (path: meta.path, size: meta.size, sha256: meta.sha256));
      } catch (e) {
        failed.add('$id: promote failed: $e');
      }
    }
    // 变更日志（spec §6.1）：本机设备目录 commit 入未同步队列
    if (committed.isNotEmpty && syncJournal != null) {
      await syncJournal!.appendCommit(deviceId, space, committed);
    }
    return (committed, failed);
  }

  // ────────────────────────────── delete / recycle ──

  /// 删除：仅移入回收站（spec §2.7）。返回 recycle_path。
  /// 成功后经 [syncJournal] 内联记日志。
  Future<String> delete(
      String targetDeviceId, String space, String relPath) async {
    final abs = _resolveInSpace(targetDeviceId, space, relPath);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw StoreException(StoreError.notFound, relPath);
    }
    await _checkNoSymlinkEscape(targetDeviceId, space, abs, relPath);
    final normalized = normalizeStorePath(relPath);
    final recycled = await _moveToRecycle(targetDeviceId, space, normalized);
    if (syncJournal != null) {
      await syncJournal!.appendDelete(targetDeviceId, space, normalized);
    }
    return recycled;
  }

  Future<String> _moveToRecycle(
      String deviceId, String space, String normalizedRel) async {
    final abs = _resolveInSpace(deviceId, space, normalizedRel);
    final date = _today();
    var recycleRel = p.join('.recycle', date, deviceId, space, normalizedRel);
    var dest = p.join(root.path, recycleRel);
    if (await FileSystemEntity.isDirectory(abs)) {
      // 目录整体移动
    } else if (!await File(abs).exists()) {
      throw StoreException(StoreError.notFound, normalizedRel);
    }
    if (await FileSystemEntity.type(dest, followLinks: false) !=
        FileSystemEntityType.notFound) {
      recycleRel =
          '$recycleRel~${DateTime.now().millisecondsSinceEpoch}';
      dest = p.join(root.path, recycleRel);
    }
    await Directory(p.dirname(dest)).create(recursive: true);
    await FileSystemEntity.isDirectory(abs)
        ? await Directory(abs).rename(dest)
        : await File(abs).rename(dest);
    _hashCache.remove(abs);
    return recycleRel.replaceAll(p.separator, '/');
  }

  /// 回收站重名冲突后缀（`~<毫秒>`）的剥除：还原路径推导原路径用。
  static String _stripRecycleSuffix(String name) =>
      name.replaceFirst(RegExp(r'~\d{10,}$'), '');

  /// 回收站列表（按删除时间新→旧）。
  Future<List<RecycleEntry>> recycleList() async {
    final recycleDir = Directory(p.join(root.path, '.recycle'));
    if (!await recycleDir.exists()) return const [];
    final entries = <RecycleEntry>[];
    await for (final dateDir in recycleDir.list()) {
      if (dateDir is! Directory) continue;
      final date = p.basename(dateDir.path);
      await for (final devDir in dateDir.list()) {
        if (devDir is! Directory) continue;
        final device = p.basename(devDir.path);
        await for (final spaceDir in devDir.list()) {
          if (spaceDir is! Directory) continue;
          final space = p.basename(spaceDir.path);
          await for (final entity in spaceDir.list(recursive: false)) {
            final name = p.basename(entity.path);
            if (name.startsWith('.')) continue;
            final rel = p.relative(entity.path, from: spaceDir.path);
            final relParts = p.split(rel);
            relParts[relParts.length - 1] =
                _stripRecycleSuffix(relParts.last);
            entries.add(RecycleEntry(
              recyclePath: p
                  .relative(entity.path, from: root.path)
                  .replaceAll(p.separator, '/'),
              originDevice: device,
              space: space,
              originPath: relParts.join('/'),
              size: await _entitySize(entity),
              deletedAtMs: _parseRecycleDate(date, entity),
            ));
          }
        }
      }
    }
    entries.sort((a, b) => b.deletedAtMs.compareTo(a.deletedAtMs));
    return entries;
  }

  /// 还原：移回原路径；原位置已有文件时先将其移入回收站（spec §2.8）。
  Future<String> recycleRestore(String recyclePath) async {
    final normalized = recyclePath.replaceAll('\\', '/');
    if (!normalized.startsWith('.recycle/') || normalized.contains('..')) {
      throw StoreException(StoreError.badPath, 'invalid recycle path');
    }
    final abs = p.join(root.path, normalized);
    final type = await FileSystemEntity.type(abs, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw StoreException(StoreError.notFound, recyclePath);
    }
    // 结构：.recycle/<date>/<device>/<space>/<originPath>（末段剥除 ~后缀）
    final parts = normalized.split('/');
    if (parts.length < 5) {
      throw StoreException(StoreError.badPath, 'malformed recycle path');
    }
    final device = parts[2];
    final space = parts[3];
    final originParts = parts.sublist(4).toList();
    originParts[originParts.length - 1] =
        _stripRecycleSuffix(originParts.last);
    final originRel = originParts.join('/');
    final destAbs = _resolveInSpace(device, space, originRel);
    if (await FileSystemEntity.type(destAbs, followLinks: false) !=
        FileSystemEntityType.notFound) {
      await _moveToRecycle(device, space, originRel);
    }
    await Directory(p.dirname(destAbs)).create(recursive: true);
    type == FileSystemEntityType.directory
        ? await Directory(abs).rename(destAbs)
        : await File(abs).rename(destAbs);
    // 空的日期目录顺手清理
    await _pruneEmptyRecycleDirs();
    return originRel;
  }

  /// 清空回收站（仅 master 本机用户，ACL 在上层强制）。返回清理字节数。
  Future<int> recycleEmpty() async {
    final recycleDir = Directory(p.join(root.path, '.recycle'));
    if (!await recycleDir.exists()) return 0;
    var purged = 0;
    await for (final entity in recycleDir.list(recursive: true)) {
      if (entity is File) purged += await entity.length();
    }
    await recycleDir.delete(recursive: true);
    return purged;
  }

  // ────────────────────────────── stats / gc ──

  /// 用量统计（spec §2.9）。
  Future<Map<String, dynamic>> stats() async {
    final devices = <String, Map<String, int>>{};
    if (await root.exists()) {
      await for (final entity in root.list()) {
        if (entity is! Directory) continue;
        final deviceId = p.basename(entity.path);
        if (!isValidDeviceId(deviceId)) continue;
        final perSpace = <String, int>{};
        for (final space in StoreSpace.all) {
          perSpace[space] = await _dirSize(
              Directory(p.join(entity.path, space)),
              skipDotDirs: true);
        }
        devices[deviceId] = perSpace;
      }
    }
    var stagingBytes = 0;
    for (final deviceId in devices.keys) {
      for (final space in StoreSpace.all) {
        stagingBytes += await _dirSize(
            Directory(p.join(root.path, deviceId, space, '.staging')));
      }
    }
    return <String, dynamic>{
      'devices': devices,
      'staging_bytes': stagingBytes,
      'recycle_bytes':
          await _dirSize(Directory(p.join(root.path, '.recycle'))),
    };
  }

  /// 永久删除某设备目录（方案 §5.4 / §7.2：换机后旧镜像手删）。
  ///
  /// 禁止删除 [selfDeviceId]；返回删除前占用字节数。
  Future<int> purgeDevice(String deviceId, {required String selfDeviceId}) async {
    if (!isValidDeviceId(deviceId)) {
      throw StoreException(StoreError.badPath, 'invalid device id');
    }
    if (deviceId == selfDeviceId) {
      throw StoreException(StoreError.aclDenied, 'cannot purge self');
    }
    final dir = Directory(p.join(root.path, deviceId));
    if (!await dir.exists()) {
      throw StoreException(StoreError.notFound, deviceId);
    }
    final bytes = await _dirSize(dir);
    await dir.delete(recursive: true);
    return bytes;
  }

  /// 清空本机设备目录（危险区 §7.5）：删四分区含 staging，**不**动他端镜像 /
  /// `.recycle` / `.system`。返回释放字节数。
  Future<int> wipeSelf(String selfDeviceId) async {
    if (!isValidDeviceId(selfDeviceId)) {
      throw StoreException(StoreError.badPath, 'invalid device id');
    }
    final dir = _deviceDir(selfDeviceId);
    if (!await dir.exists()) return 0;
    final bytes = await _dirSize(dir);
    await dir.delete(recursive: true);
    await dir.create(recursive: true);
    _hashCache.clear();
    return bytes;
  }

  /// 清理超时未 commit 的暂存（默认 24h，spec §2.4）。
  Future<int> gcStaging({Duration olderThan = const Duration(hours: 24)}) async {
    var removed = 0;
    final deadline = DateTime.now().subtract(olderThan);
    if (!await root.exists()) return 0;
    await for (final devDir in root.list()) {
      if (devDir is! Directory || !isValidDeviceId(p.basename(devDir.path))) {
        continue;
      }
      for (final space in StoreSpace.all) {
        final staging = Directory(p.join(devDir.path, space, '.staging'));
        if (!await staging.exists()) continue;
        await for (final f in staging.list()) {
          if (f is! File) continue;
          final mtime = (await f.stat()).modified;
          if (mtime.isBefore(deadline)) {
            await f.delete();
            if (f.path.endsWith('.json')) removed++;
          }
        }
      }
    }
    return removed;
  }

  /// 清理超过保留期的回收站日期目录（默认 30 天，spec §2.7）。
  /// 返回清理的字节数。
  Future<int> gcRecycle({Duration olderThan = const Duration(days: 30)}) async {
    final recycleDir = Directory(p.join(root.path, '.recycle'));
    if (!await recycleDir.exists()) return 0;
    final today = DateTime.now();
    final cutoff = DateTime(today.year, today.month, today.day)
        .subtract(olderThan);
    var purgedBytes = 0;
    await for (final dateDir in recycleDir.list()) {
      if (dateDir is! Directory) continue;
      final parsed = DateTime.tryParse(p.basename(dateDir.path));
      if (parsed == null) continue;
      final dateOnly = DateTime(parsed.year, parsed.month, parsed.day);
      if (!dateOnly.isBefore(cutoff)) continue;
      purgedBytes += await _dirSize(dateDir);
      await dateDir.delete(recursive: true);
    }
    await _pruneEmptyRecycleDirs();
    return purgedBytes;
  }

  // ────────────────────────────── 内部工具 ──

  Future<String> _hashOf(File f, FileStat stat) async {
    final key = f.path;
    final cached = _hashCache[key];
    final mtime = stat.modified.millisecondsSinceEpoch;
    if (cached != null && cached.$1 == mtime && cached.$2 == stat.size) {
      return cached.$3;
    }
    final digest = await crypto.sha256.bind(f.openRead()).first;
    _hashCache[key] = (mtime, stat.size, digest.toString());
    return digest.toString();
  }

  Future<int> _dirSize(Directory dir, {bool skipDotDirs = false}) async {
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entity in dir.list(recursive: true)) {
      if (entity is! File) continue;
      if (skipDotDirs) {
        final rel = p.relative(entity.path, from: dir.path);
        if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
      }
      total += await entity.length();
    }
    return total;
  }

  Future<int> _entitySize(FileSystemEntity entity) async {
    if (entity is File) return entity.length();
    if (entity is Directory) return _dirSize(entity);
    return 0;
  }

  int _parseRecycleDate(String dateDir, FileSystemEntity entity) {
    final parsed = DateTime.tryParse(dateDir);
    if (parsed != null) return parsed.millisecondsSinceEpoch;
    if (entity is File) {
      return 0;
    }
    return 0;
  }

  Future<void> _pruneEmptyRecycleDirs() async {
    final recycleDir = Directory(p.join(root.path, '.recycle'));
    if (!await recycleDir.exists()) return;
    await for (final dateDir in recycleDir.list()) {
      if (dateDir is! Directory) continue;
      if (await dateDir.list().isEmpty) await dateDir.delete();
    }
  }

  static String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}

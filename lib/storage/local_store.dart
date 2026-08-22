import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'store_protocol.dart';
import 'sync_journal.dart';
import 'commit_retention.dart';

/// store 层错误（StoreService 转为 error 帧）。
class StoreException implements Exception {
  StoreException(this.code, [this.message = '']);
  final String code;
  final String message;
  @override
  String toString() => 'StoreException($code): $message';
}

/// list/meta 返回的文件/目录条目。
class StoreEntry {
  StoreEntry({
    required this.path,
    required this.size,
    required this.sha256,
    required this.mtimeMs,
    this.kind = 'file',
  });

  final String path;
  final int size;
  final String sha256;
  final int mtimeMs;

  /// `'file'` | `'dir'`（有限 depth 列表时目录也会出现）。
  final String kind;

  bool get isDir => kind == 'dir';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'path': path,
        'size': size,
        'sha256': sha256,
        'mtime': mtimeMs,
        if (kind != 'file') 'kind': kind,
      };

  factory StoreEntry.fromJson(Map<String, dynamic> json) => StoreEntry(
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        sha256: json['sha256'] as String? ?? '',
        mtimeMs: (json['mtime'] as num?)?.toInt() ??
            (json['mtime_ms'] as num?)?.toInt() ??
            0,
        kind: json['kind'] as String? ?? 'file',
      );
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
/// .versions/<device_id>/<space>/...  覆盖旧版本（versions.* 只读）
/// .recycle/<yyyy-MM-dd>/<device_id>/<space>/...  回收站
/// ```
class LocalStore {
  /// store 根目录（…/shepaw/store）。
  final Directory root;

  /// 同一路径连续覆盖时，窗口内未保护版本合并为一次变更（替换索引末条）。
  /// 设为 [Duration.zero] 可关闭合并（测试或需要逐次留档时）。
  final Duration versionCoalesceWindow;

  /// 默认合并窗口：一次编辑会话内的多次 commit 只留最终版本。
  static const Duration defaultVersionCoalesceWindow = Duration(seconds: 30);

  static const _uuid = Uuid();
  static const maxReadChunk = 64 * 1024;

  /// 变更日志挂接点（docs/storage_protocol_spec.md §6.1）。
  /// 由 SyncEngine.start 设置；commit/delete 成功路径内联调用，
  /// 保证"落盘成功即入队"无窗口期。
  static SyncJournal? syncJournal;

  /// upload_id 形态校验（安全：调用者可自报 upload_id，
  /// 未校验可路径穿越写任意设备目录）。
  static final _uploadIdPattern = RegExp(r'^[A-Za-z0-9-]{1,64}$');
  static void checkUploadId(String uploadId) {
    if (!_uploadIdPattern.hasMatch(uploadId)) {
      throw StoreException(StoreError.badOp, 'invalid upload_id');
    }
  }

  /// sha256 内存缓存：path → (mtime, size, hash)。
  final Map<String, (int, int, String)> _hashCache = {};

  final File _usageCacheFile;
  Map<String, dynamic>? _usageCache;
  Future<void>? _usageRefresh;
  bool _usageDirty = false;
  final StreamController<void> _usageTick = StreamController<void>.broadcast();

  LocalStore({
    required this.root,
    this.versionCoalesceWindow = defaultVersionCoalesceWindow,
  }) : _usageCacheFile =
            File(p.join(root.path, '.system', 'usage_cache.json'));

  /// 后台全量统计完成或增量更新后通知 UI。
  Stream<void> get usageUpdates => _usageTick.stream;

  // ────────────────────────────── 路径解析（防逃逸，spec §4）──

  Directory _deviceDir(String deviceId) {
    if (!isValidDeviceId(deviceId)) {
      throw StoreException(StoreError.badOp, 'invalid device_id');
    }
    return Directory(p.join(root.path, deviceId));
  }

  String _spaceDir(String deviceId, String space) {
    // 内置 + 已声明自定义空间（如 memory）：语法合法即可寻址；
    // 属性/ACL 由上层 space registry 裁定（spec §0.5）。
    if (!StoreSpace.isValidSyntax(space)) {
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

  /// 列出 space 下条目。
  ///
  /// - [depth] 省略 / ≤0：递归列出全部文件（兼容同步；不含目录行）。
  /// - [depth] ≥1：从 [prefix] 目录起最多下钻 depth 层，含 `kind:dir`，
  ///   便于跨 agent（`agents/<uuid>/`）一层一层浏览。
  /// - [computeHash] 为 false 时跳过 SHA-256（浏览/搜索用，避免打开即全量哈希）。
  Future<List<StoreEntry>> list(
    String deviceId,
    String space, {
    String? prefix,
    int limit = 1000,
    int? depth,
    bool computeHash = true,
  }) async {
    final baseAbs = _spaceDir(deviceId, space);
    final base = Directory(baseAbs);
    if (!await base.exists()) return const [];
    final maxDepth = (depth != null && depth > 0) ? depth : 0;
    final entries = <StoreEntry>[];

    Future<String> hashOf(File entity, FileStat stat) async =>
        computeHash ? await _hashOf(entity, stat) : '';

    if (maxDepth > 0) {
      final startRel = (prefix ?? '').replaceAll(RegExp(r'^/+|/+$'), '');
      final startAbs =
          startRel.isEmpty ? baseAbs : _resolveInSpace(deviceId, space, startRel);
      final startType =
          await FileSystemEntity.type(startAbs, followLinks: true);
      if (startType != FileSystemEntityType.directory) return const [];

      Future<void> walkShallow(
          String dirAbs, String rel, int remaining) async {
        if (entries.length >= limit || remaining < 1) return;
        final dir = Directory(dirAbs);
        await for (final entity in dir.list(followLinks: true)) {
          if (entries.length >= limit) return;
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;
          final childRel = rel.isEmpty ? name : '$rel/$name';
          if (entity is Directory) {
            final stat = await entity.stat();
            entries.add(StoreEntry(
              path: childRel.replaceAll(p.separator, '/'),
              size: 0,
              sha256: '',
              mtimeMs: stat.modified.millisecondsSinceEpoch,
              kind: 'dir',
            ));
            if (remaining > 1) {
              await walkShallow(entity.path, childRel, remaining - 1);
            }
          } else if (entity is File) {
            final stat = await entity.stat();
            entries.add(StoreEntry(
              path: childRel.replaceAll(p.separator, '/'),
              size: stat.size,
              sha256: await hashOf(entity, stat),
              mtimeMs: stat.modified.millisecondsSinceEpoch,
              kind: 'file',
            ));
          }
        }
      }

      await walkShallow(startAbs, startRel, maxDepth);
      entries.sort((a, b) => a.path.compareTo(b.path));
      return entries;
    }

    await for (final entity in base.list(recursive: true)) {
      if (entity is! File) continue;
      final rel = p.relative(entity.path, from: baseAbs);
      if (rel.split(p.separator).any((s) => s.startsWith('.'))) continue;
      if (prefix != null && !rel.startsWith(prefix)) continue;
      final stat = await entity.stat();
      entries.add(StoreEntry(
        path: rel.replaceAll(p.separator, '/'),
        size: stat.size,
        sha256: await hashOf(entity, stat),
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

  /// 轻量判断路径是文件还是目录（不列清单）。
  ///
  /// 跟随符号链接，与 [list] `depth≥1` 一致；导航/探测用，不做写路径逃逸校验。
  /// 返回 `'file'` 或 `'dir'`；不存在抛 [StoreException] `not_found`。
  Future<String> entityKind(
      String deviceId, String space, String relPath) async {
    if (relPath.isEmpty) {
      final dir = Directory(_spaceDir(deviceId, space));
      if (!await dir.exists()) {
        throw StoreException(StoreError.notFound, space);
      }
      return 'dir';
    }
    final abs = _resolveInSpace(deviceId, space, relPath);
    final type = await FileSystemEntity.type(abs, followLinks: true);
    if (type == FileSystemEntityType.notFound ||
        type == FileSystemEntityType.link) {
      throw StoreException(StoreError.notFound, relPath);
    }
    return type == FileSystemEntityType.file ? 'file' : 'dir';
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
    checkUploadId(id);
    if (!isValidContentSha256(sha256)) {
      throw StoreException(StoreError.badOp, 'invalid sha256');
    }
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
    checkUploadId(uploadId);
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
  /// 再逐个 rename；目标已存在时旧版本先进 `.versions` 并保留索引。
  /// 成功后经 [syncJournal] 内联记日志（本机设备目录变更入未同步队列）。
  /// 可选 [retention]：转正成功后按策略剪枝同分区顶层目录（§13 / spec retention）。
  /// 可选 [manifest]：写入任务 `.nexuspouch/manifest.json`（血缘）。
  /// 可选 [publish]：标记版本 `protected`（发布产物修剪时保留）。
  /// 返回（已转正文件清单，失败项）。
  Future<(List<({String path, int size, String sha256})>, List<String>)>
      commit(
    String deviceId,
    String space,
    List<String> uploadIds, {
    Map<String, dynamic>? retention,
    Map<String, dynamic>? manifest,
    bool publish = false,
  }) async {
    final stagingDir = _stagingDir(deviceId, space);
    final verified = <(String, _StagingMeta, File)>[];
    final failed = <String>[];

    // 阶段一：全量校验（spec §2.6：全部通过才进入转正）
    for (final id in uploadIds) {
      checkUploadId(id);
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
    var spaceDelta = 0;
    for (final (id, meta, partFile) in verified) {
      try {
        final finalAbs = _resolveInSpace(deviceId, space, meta.path);
        // 转正前检查目标路径（含父目录）无 symlink 逃逸
        await _checkNoSymlinkEscape(deviceId, space, finalAbs, meta.path);
        var oldSize = 0;
        if (await File(finalAbs).exists()) {
          oldSize = await File(finalAbs).length();
          // 被覆盖旧版本进 .versions（spec §1.5 / §2.6）
          await _archiveToVersions(deviceId, space, meta.path);
        }
        await File(finalAbs).parent.create(recursive: true);
        await partFile.rename(finalAbs);
        _hashCache.remove(finalAbs);
        await File(p.join(stagingDir, '$id.json')).delete();
        await _recordCurrentVersion(
          deviceId,
          space,
          meta.path,
          sha256: meta.sha256,
          size: meta.size,
          protected: publish,
        );
        committed.add(
            (path: meta.path, size: meta.size, sha256: meta.sha256));
        spaceDelta += meta.size - oldSize;
      } catch (e) {
        failed.add('$id: promote failed: $e');
      }
    }
    // 变更日志（spec §6.1）：本机设备目录 commit 入未同步队列
    if (committed.isNotEmpty && syncJournal != null) {
      await syncJournal!.appendCommit(deviceId, space, committed);
    }
    if (committed.isNotEmpty) {
      await _applyUsageDeltas(
        deviceId: deviceId,
        space: space,
        spaceDelta: spaceDelta,
      );
    }
    if (committed.isNotEmpty && retention != null) {
      final policy = CommitRetention.tryParse(retention);
      if (policy != null) {
        await CommitRetention.apply(
          this,
          deviceId: deviceId,
          space: space,
          policy: policy,
        );
      }
    }
    if (committed.isNotEmpty && manifest != null) {
      await _writeTaskManifest(deviceId, space, committed.first.path, manifest);
    }
    return (committed, failed);
  }

  // ────────────────────────────── versions / manifest（spec §1.5）──

  /// `.versions/<device>/<space>/<relpath>/`
  String _versionsDir(String deviceId, String space, String normalizedRel) =>
      p.join(root.path, '.versions', deviceId, space, normalizedRel);

  String _versionsIndexPath(String deviceId, String space, String normalizedRel) =>
      p.join(_versionsDir(deviceId, space, normalizedRel), 'index.json');

  String _versionsBlobPath(
          String deviceId, String space, String normalizedRel, String sha256) =>
      p.join(_versionsDir(deviceId, space, normalizedRel), sha256);

  Future<List<Map<String, dynamic>>> _loadVersionEntries(
      String deviceId, String space, String normalizedRel) async {
    final indexFile =
        File(_versionsIndexPath(deviceId, space, normalizedRel));
    if (!await indexFile.exists()) return [];
    try {
      final json = jsonDecode(await indexFile.readAsString());
      final list = (json is Map ? json['versions'] : null) as List? ?? const [];
      return [
        for (final e in list)
          if (e is Map) Map<String, dynamic>.from(e)
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveVersionEntries(String deviceId, String space,
      String normalizedRel, List<Map<String, dynamic>> entries) async {
    final dir = Directory(_versionsDir(deviceId, space, normalizedRel));
    await dir.create(recursive: true);
    final indexFile =
        File(_versionsIndexPath(deviceId, space, normalizedRel));
    await indexFile.writeAsString(jsonEncode({'versions': entries}));
  }

  /// 覆盖前：把正式区现有文件迁入 `.versions` 并确保索引含该版本。
  Future<void> _archiveToVersions(
      String deviceId, String space, String relPath) async {
    final normalized = normalizeStorePath(relPath);
    final abs = _resolveInSpace(deviceId, space, normalized);
    final file = File(abs);
    if (!await file.exists()) return;
    final stat = await file.stat();
    final hash = await _hashOf(file, stat);
    final entries = await _loadVersionEntries(deviceId, space, normalized);
    final already =
        entries.any((e) => e['sha256'] == hash && e['size'] == stat.size);
    if (!already) {
      final nextV = entries.isEmpty
          ? 1
          : ((entries.last['v'] as num?)?.toInt() ?? entries.length) + 1;
      entries.add(<String, dynamic>{
        'v': nextV,
        'sha256': hash,
        'size': stat.size,
        'mtime': stat.modified.millisecondsSinceEpoch,
        'protected': false,
      });
      await _saveVersionEntries(deviceId, space, normalized, entries);
    }
    final blob = File(_versionsBlobPath(deviceId, space, normalized, hash));
    await blob.parent.create(recursive: true);
    if (await blob.exists()) {
      await file.delete();
    } else {
      await file.rename(blob.path);
    }
    _hashCache.remove(abs);
  }

  /// 转正后：把当前正式区内容记入版本索引（最新一条）。
  ///
  /// 频繁覆盖时：若末条未 `protected` 且距其 mtime 仍在
  /// [versionCoalesceWindow] 内，则**替换**末条（同 v 号），不新增版本；
  /// 同时删除被替换内容的 `.versions` blob。窗口外或发布产物则新开版本。
  Future<void> _recordCurrentVersion(
    String deviceId,
    String space,
    String relPath, {
    required String sha256,
    required int size,
    bool protected = false,
  }) async {
    final normalized = normalizeStorePath(relPath);
    final abs = _resolveInSpace(deviceId, space, normalized);
    final file = File(abs);
    final mtime = await file.exists()
        ? (await file.stat()).modified.millisecondsSinceEpoch
        : DateTime.now().millisecondsSinceEpoch;
    final entries = await _loadVersionEntries(deviceId, space, normalized);
    if (entries.isNotEmpty && entries.last['sha256'] == sha256) {
      if (protected && entries.last['protected'] != true) {
        entries.last['protected'] = true;
        await _saveVersionEntries(deviceId, space, normalized, entries);
      }
      return;
    }
    if (entries.isNotEmpty &&
        !protected &&
        entries.last['protected'] != true &&
        versionCoalesceWindow > Duration.zero) {
      final lastMtime = (entries.last['mtime'] as num?)?.toInt() ?? 0;
      if (mtime - lastMtime <= versionCoalesceWindow.inMilliseconds) {
        final oldSha = '${entries.last['sha256'] ?? ''}';
        entries.last['sha256'] = sha256;
        entries.last['size'] = size;
        entries.last['mtime'] = mtime;
        await _saveVersionEntries(deviceId, space, normalized, entries);
        if (oldSha.isNotEmpty && oldSha != sha256) {
          final oldBlob =
              File(_versionsBlobPath(deviceId, space, normalized, oldSha));
          if (await oldBlob.exists()) {
            try {
              await oldBlob.delete();
            } catch (_) {}
          }
        }
        return;
      }
    }
    final nextV = entries.isEmpty
        ? 1
        : ((entries.last['v'] as num?)?.toInt() ?? entries.length) + 1;
    entries.add(<String, dynamic>{
      'v': nextV,
      'sha256': sha256,
      'size': size,
      'mtime': mtime,
      'protected': protected,
    });
    await _saveVersionEntries(deviceId, space, normalized, entries);
  }

  /// 版本清单（含当前最新；无索引时若正式区有文件则合成 v1）。
  Future<Map<String, dynamic>> versionsList(
    String deviceId,
    String space,
    String relPath,
  ) async {
    final normalized = normalizeStorePath(relPath);
    var entries = await _loadVersionEntries(deviceId, space, normalized);
    if (entries.isEmpty) {
      final abs = _resolveInSpace(deviceId, space, normalized);
      final file = File(abs);
      if (await file.exists()) {
        final stat = await file.stat();
        entries = [
          <String, dynamic>{
            'v': 1,
            'sha256': await _hashOf(file, stat),
            'size': stat.size,
            'mtime': stat.modified.millisecondsSinceEpoch,
            'protected': false,
          }
        ];
      }
    }
    return <String, dynamic>{'versions': entries};
  }

  /// 按 `vN` 或 sha256 前缀读取历史内容。
  Future<(Uint8List data, int size, bool eof)> versionsRead(
    String deviceId,
    String space,
    String relPath,
    String ref, {
    int offset = 0,
    int length = maxReadChunk,
  }) async {
    if (length < 1 || length > maxReadChunk) {
      throw StoreException(
          StoreError.badOp, 'length must be 1..$maxReadChunk');
    }
    if (offset < 0) throw StoreException(StoreError.badOp, 'negative offset');

    final normalized = normalizeStorePath(relPath);
    final parsed = parseStoreVersionRef(ref);
    if (parsed == null || parsed.isLatest) {
      throw StoreException(StoreError.badUri, 'invalid version ref $ref');
    }

    final entries = (await versionsList(deviceId, space, normalized))['versions']
        as List;
    Map<String, dynamic>? hit;
    if (parsed.kind == StoreUriRefKind.seq) {
      final v = parsed.value as int;
      for (final e in entries) {
        final m = e as Map<String, dynamic>;
        if ((m['v'] as num?)?.toInt() == v) {
          hit = m;
          break;
        }
      }
    } else {
      final prefix = (parsed.value as String).toLowerCase();
      final matches = <Map<String, dynamic>>[];
      for (final e in entries) {
        final m = e as Map<String, dynamic>;
        final sha = '${m['sha256'] ?? ''}'.toLowerCase();
        if (sha.startsWith(prefix)) matches.add(m);
      }
      if (matches.length > 1) {
        throw StoreException(StoreError.ambiguousRef, prefix);
      }
      if (matches.length == 1) hit = matches.first;
    }
    if (hit == null) {
      throw StoreException(StoreError.notFound, 'ref=$ref');
    }

    final sha = '${hit['sha256']}';
    final size = (hit['size'] as num?)?.toInt() ?? 0;
    // 优先 blob；否则若与正式区哈希一致则读正式区
    final blob = File(_versionsBlobPath(deviceId, space, normalized, sha));
    File source;
    if (await blob.exists()) {
      source = blob;
    } else {
      final live = File(_resolveInSpace(deviceId, space, normalized));
      if (!await live.exists()) {
        throw StoreException(StoreError.notFound, 'blob missing for $sha');
      }
      final liveStat = await live.stat();
      final liveHash = await _hashOf(live, liveStat);
      if (liveHash != sha) {
        throw StoreException(StoreError.notFound, 'blob missing for $sha');
      }
      source = live;
    }

    if (offset >= size) {
      return (Uint8List(0), size, true);
    }
    final end = (offset + length).clamp(0, size);
    final raf = await source.open();
    try {
      await raf.setPosition(offset);
      final data = await raf.read(end - offset);
      return (data, size, end >= size);
    } finally {
      await raf.close();
    }
  }

  /// 任务血缘：在路径祖先中查找 `.nexuspouch/manifest.json`。
  Future<Map<String, dynamic>> readManifest(
    String deviceId,
    String space,
    String relPath,
  ) async {
    final normalized = normalizeStorePath(relPath);
    final segments = normalized.split('/');
    // 从文件所在目录向上，到 space 根下第一层任务目录
    for (var i = segments.length - 1; i >= 1; i--) {
      final taskRel = segments.sublist(0, i).join('/');
      final manifestAbs = p.join(
          _spaceDir(deviceId, space), taskRel, '.nexuspouch', 'manifest.json');
      final f = File(manifestAbs);
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        if (decoded is Map<String, dynamic>) return decoded;
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    }
    // 单段路径：task 即第一段（文件本身也在任务根下时）
    if (segments.length == 1) {
      return <String, dynamic>{};
    }
    return <String, dynamic>{};
  }

  Future<void> _writeTaskManifest(
    String deviceId,
    String space,
    String fileRelPath,
    Map<String, dynamic> manifest,
  ) async {
    final normalized = normalizeStorePath(fileRelPath);
    final segments = normalized.split('/');
    final taskRel =
        segments.length > 1 ? segments.first : normalized;
    // 点前缀目录不走 normalizeStorePath；直接拼在 space 下
    final dir = Directory(
        p.join(_spaceDir(deviceId, space), taskRel, '.nexuspouch'));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'manifest.json'));
    await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest));
  }

  // ────────────────────────────── rename ──

  /// 同 space 内改名（不经回收站）。用于绑定 rename 识别，保留本地文件本体。
  /// 镜像队列记 `delete(from)` + `commit(to)`，远端仍按增删同步。
  Future<void> rename(
    String deviceId,
    String space,
    String fromRel,
    String toRel, {
    required String sha256,
    required int size,
  }) async {
    final fromNorm = normalizeStorePath(fromRel);
    final toNorm = normalizeStorePath(toRel);
    if (fromNorm == toNorm) return;
    final fromAbs = _resolveInSpace(deviceId, space, fromNorm);
    final toAbs = _resolveInSpace(deviceId, space, toNorm);
    final fromType =
        await FileSystemEntity.type(fromAbs, followLinks: false);
    if (fromType == FileSystemEntityType.notFound) {
      throw StoreException(StoreError.notFound, fromNorm);
    }
    if (fromType != FileSystemEntityType.file) {
      throw StoreException(StoreError.badOp, 'rename source not a file');
    }
    await _checkNoSymlinkEscape(deviceId, space, fromAbs, fromNorm);
    final toType = await FileSystemEntity.type(toAbs, followLinks: false);
    if (toType != FileSystemEntityType.notFound) {
      throw StoreException(StoreError.badOp, 'rename dest exists: $toNorm');
    }
    await Directory(p.dirname(toAbs)).create(recursive: true);
    await File(fromAbs).rename(toAbs);
    _hashCache.remove(fromAbs);
    if (syncJournal != null) {
      await syncJournal!.appendDelete(deviceId, space, fromNorm);
      await syncJournal!.appendCommit(deviceId, space, [
        (path: toNorm, size: size, sha256: sha256),
      ]);
    }
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
    final bytes = await _entitySize(
      type == FileSystemEntityType.directory ? Directory(abs) : File(abs),
    );
    final recycled = await _moveToRecycle(targetDeviceId, space, normalized);
    if (syncJournal != null) {
      await syncJournal!.appendDelete(targetDeviceId, space, normalized);
    }
    await _applyUsageDeltas(
      deviceId: targetDeviceId,
      space: space,
      spaceDelta: -bytes,
      recycleDelta: bytes,
    );
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
    _markUsageDirty();
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
    await _applyUsageDeltas(recycleDelta: -purged);
    return purged;
  }

  // ────────────────────────────── stats / gc ──

  /// 用量统计（spec §2.9）。
  ///
  /// [blocking] 为 true（默认）时：无完整缓存则当场全量扫描（单测 / 设置页）。
  /// 为 false 时立即返回缓存或空值，并在后台全量刷新——打开本机空间不再卡住。
  /// 完整缓存之后由 commit/delete 增量维护。
  Future<Map<String, dynamic>> stats({bool blocking = true}) async {
    await _loadUsageCache();
    if (_usageComplete && !_usageDirty) {
      return _publicUsageStats();
    }
    if (!blocking) {
      unawaited(_scheduleUsageRefresh());
      return _publicUsageStats();
    }
    await _scheduleUsageRefresh();
    return _publicUsageStats();
  }

  /// 强制全量重算（下拉刷新）。
  Future<Map<String, dynamic>> refreshStats() async {
    await _recomputeUsageCache();
    return _publicUsageStats();
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
    await _removeDeviceUsage(deviceId);
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
    await _zeroDeviceUsage(selfDeviceId);
    return bytes;
  }

  /// 清理超时未 commit 的暂存（默认 24h，spec §2.4）。
  /// 优先用 `.json` 的 `created_ms`，避免活跃 chunk 写刷新 mtime 绕过 GC。
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
        final seen = <String>{};
        await for (final f in staging.list()) {
          if (f is! File) continue;
          final name = p.basename(f.path);
          String? id;
          if (name.endsWith('.json')) {
            id = name.substring(0, name.length - 5);
          } else if (name.endsWith('.part')) {
            id = name.substring(0, name.length - 5);
          }
          if (id == null || !seen.add(id)) continue;
          final created = await _stagingCreated(staging.path, id, f);
          if (created.isBefore(deadline)) {
            final part = File(p.join(staging.path, '$id.part'));
            final meta = File(p.join(staging.path, '$id.json'));
            if (await part.exists()) await part.delete();
            if (await meta.exists()) await meta.delete();
            removed++;
          }
        }
      }
    }
    if (removed > 0) _markUsageDirty();
    return removed;
  }

  Future<DateTime> _stagingCreated(
      String stagingDir, String id, File fallback) async {
    final metaFile = File(p.join(stagingDir, '$id.json'));
    if (await metaFile.exists()) {
      try {
        final raw =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final ms = raw['created_ms'] as int?;
        if (ms != null && ms > 0) {
          return DateTime.fromMillisecondsSinceEpoch(ms);
        }
      } catch (_) {}
    }
    return (await fallback.stat()).modified;
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
    if (purgedBytes > 0) {
      await _applyUsageDeltas(recycleDelta: -purgedBytes);
    }
    return purgedBytes;
  }

  // ────────────────────────────── 用量缓存 ──

  bool get _usageComplete => _usageCache?['complete'] == true;

  Map<String, dynamic> _emptyUsageStats() => <String, dynamic>{
        'devices': <String, Map<String, int>>{},
        'staging_bytes': 0,
        'recycle_bytes': 0,
        'complete': false,
        'updated_ms': 0,
      };

  Map<String, dynamic> _publicUsageStats() {
    final raw = _usageCache ?? _emptyUsageStats();
    return <String, dynamic>{
      'devices': raw['devices'] ?? <String, Map<String, int>>{},
      'staging_bytes': _asInt(raw['staging_bytes']),
      'recycle_bytes': _asInt(raw['recycle_bytes']),
    };
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }

  Future<void> _loadUsageCache() async {
    if (_usageCache != null) return;
    if (!await _usageCacheFile.exists()) {
      _usageCache = _emptyUsageStats();
      return;
    }
    try {
      final decoded = jsonDecode(await _usageCacheFile.readAsString());
      if (decoded is! Map) {
        _usageCache = _emptyUsageStats();
        return;
      }
      _usageCache = _normalizeUsageCache(Map<String, dynamic>.from(decoded));
    } catch (_) {
      _usageCache = _emptyUsageStats();
    }
  }

  Map<String, dynamic> _normalizeUsageCache(Map<String, dynamic> raw) {
    final devices = <String, Map<String, int>>{};
    final rawDevices = raw['devices'];
    if (rawDevices is Map) {
      for (final e in rawDevices.entries) {
        final per = <String, int>{};
        if (e.value is Map) {
          for (final s in (e.value as Map).entries) {
            per['${s.key}'] = _asInt(s.value);
          }
        }
        devices['${e.key}'] = per;
      }
    }
    return <String, dynamic>{
      'devices': devices,
      'staging_bytes': _asInt(raw['staging_bytes']),
      'recycle_bytes': _asInt(raw['recycle_bytes']),
      'complete': raw['complete'] == true,
      'updated_ms': _asInt(raw['updated_ms']),
    };
  }

  Future<void> _saveUsageCache() async {
    final cache = _usageCache;
    if (cache == null) return;
    try {
      await _usageCacheFile.parent.create(recursive: true);
      final tmp = File(
          '${_usageCacheFile.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsString(jsonEncode(cache));
      await tmp.rename(_usageCacheFile.path);
    } on FileSystemException {
      // store 根已被删（测试 tearDown / wipe）时忽略
    }
  }

  void _notifyUsage() {
    if (!_usageTick.isClosed) _usageTick.add(null);
  }

  Future<void> _scheduleUsageRefresh() {
    return _usageRefresh ??= _recomputeUsageCache().whenComplete(() {
      _usageRefresh = null;
      if (_usageDirty) {
        _usageDirty = false;
        unawaited(_scheduleUsageRefresh());
      }
    });
  }

  void _markUsageDirty() {
    _usageDirty = true;
  }

  Future<void> _recomputeUsageCache() async {
    try {
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
      _usageCache = <String, dynamic>{
        'devices': devices,
        'staging_bytes': stagingBytes,
        'recycle_bytes':
            await _dirSize(Directory(p.join(root.path, '.recycle'))),
        'complete': true,
        'updated_ms': DateTime.now().millisecondsSinceEpoch,
      };
      _usageDirty = false;
      await _saveUsageCache();
      _notifyUsage();
    } catch (_) {
      // 扫描期间目录被删（测试 tearDown / wipe）
    }
  }

  Map<String, int> _deviceSpaceMap(String deviceId) {
    final devices = _usageCache?['devices'];
    if (devices is Map<String, Map<String, int>>) {
      return devices.putIfAbsent(deviceId, () => <String, int>{});
    }
    if (devices is Map) {
      final existing = devices[deviceId];
      if (existing is Map<String, int>) return existing;
      final per = <String, int>{};
      if (existing is Map) {
        for (final s in existing.entries) {
          per['${s.key}'] = _asInt(s.value);
        }
      }
      devices[deviceId] = per;
      return per;
    }
    final fresh = <String, Map<String, int>>{deviceId: <String, int>{}};
    _usageCache?['devices'] = fresh;
    return fresh[deviceId]!;
  }

  Future<void> _applyUsageDeltas({
    String? deviceId,
    String? space,
    int spaceDelta = 0,
    int stagingDelta = 0,
    int recycleDelta = 0,
  }) async {
    if (spaceDelta == 0 && stagingDelta == 0 && recycleDelta == 0) return;
    await _loadUsageCache();
    final cache = _usageCache;
    if (cache == null || cache['complete'] != true) {
      _markUsageDirty();
      return;
    }
    if (deviceId != null && space != null && spaceDelta != 0) {
      final per = _deviceSpaceMap(deviceId);
      final next = (per[space] ?? 0) + spaceDelta;
      per[space] = next < 0 ? 0 : next;
    }
    if (stagingDelta != 0) {
      final next = _asInt(cache['staging_bytes']) + stagingDelta;
      cache['staging_bytes'] = next < 0 ? 0 : next;
    }
    if (recycleDelta != 0) {
      final next = _asInt(cache['recycle_bytes']) + recycleDelta;
      cache['recycle_bytes'] = next < 0 ? 0 : next;
    }
    cache['updated_ms'] = DateTime.now().millisecondsSinceEpoch;
    await _saveUsageCache();
    _notifyUsage();
  }

  Future<void> _removeDeviceUsage(String deviceId) async {
    await _loadUsageCache();
    final cache = _usageCache;
    if (cache == null || cache['complete'] != true) {
      _markUsageDirty();
      return;
    }
    final devices = cache['devices'];
    if (devices is Map) devices.remove(deviceId);
    cache['updated_ms'] = DateTime.now().millisecondsSinceEpoch;
    await _saveUsageCache();
    _notifyUsage();
  }

  Future<void> _zeroDeviceUsage(String deviceId) async {
    await _loadUsageCache();
    final cache = _usageCache;
    if (cache == null || cache['complete'] != true) {
      _markUsageDirty();
      return;
    }
    _deviceSpaceMap(deviceId)
      ..clear()
      ..addEntries([for (final s in StoreSpace.all) MapEntry(s, 0)]);
    cache['updated_ms'] = DateTime.now().millisecondsSinceEpoch;
    await _saveUsageCache();
    _notifyUsage();
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
      try {
        total += await entity.length();
      } on FileSystemException {
        continue;
      }
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

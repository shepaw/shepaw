//! 目录绑定（M6a）：用户选择的本地目录 → store 摄取。
//!
//! - 单向输入源：外部目录内容摄取进 `files/<device>/<folder>/`（copy），
//!   删除进回收站；store 内始终是真实文件（无符号链接）；
//! - 对账 = 全量扫描 + sha256/size/mtime 对比（事件只是唤醒信号，
//!   正确性不依赖事件）；`startAutoSync` = DirectoryWatcher 去抖 + 周期兜底；
//! - 摄取走 LocalStore 写路径（write.begin/chunk/commit），自动进
//!   SyncJournal → 镜像到 master；忽略规则与 `.` 前缀默认跳过。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:watcher/watcher.dart';

import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';

class FolderBinding {
  FolderBinding({
    required this.id,
    required this.label,
    required this.external,
    this.space = StoreSpace.files,
    required this.folder,
    this.ignore = const [],
    required this.createdAt,
  });

  final String id;
  final String label;
  final String external;
  final String space;
  final String folder;
  final List<String> ignore;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'external': external,
        'space': space,
        'folder': folder,
        'ignore': ignore,
        'created_at': createdAt.toIso8601String(),
      };

  static FolderBinding fromJson(Map<String, dynamic> j) => FolderBinding(
        id: j['id'] as String,
        label: j['label'] as String? ?? '',
        external: j['external'] as String,
        space: j['space'] as String? ?? StoreSpace.files,
        folder: j['folder'] as String? ?? '',
        ignore: ((j['ignore'] as List?) ?? const []).cast<String>(),
        createdAt:
            DateTime.tryParse(j['created_at'] as String? ?? '') ?? DateTime.now(),
      );
}

class BindingSyncReport {
  BindingSyncReport(this.bindingId);
  final String bindingId;
  int added = 0;
  int updated = 0;
  int deleted = 0;
  int skipped = 0;
  final List<String> errors = <String>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
        'binding_id': bindingId,
        'added': added,
        'updated': updated,
        'deleted': deleted,
        'skipped': skipped,
        'errors': errors,
      };
}

class FolderBindingService {
  FolderBindingService._();
  static final FolderBindingService instance = FolderBindingService._();

  final _uuid = const Uuid();
  void Function()? _stopPeriodic;
  final List<StreamSubscription<WatchEvent>> _watchSubs = [];
  final Map<String, Timer> _debounceByBinding = {};
  bool _autoSyncStarted = false;

  Future<Directory> _systemDir() async {
    final root = await StoreService.instance.storeRoot();
    final dir = Directory(p.join(root.path, '.system'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _configFile() async =>
      File(p.join((await _systemDir()).path, 'bindings.json'));

  Future<File> _indexFile(String bindingId) async {
    final dir = Directory(p.join((await _systemDir()).path, 'binding_index'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, '$bindingId.json'));
  }

  Future<List<FolderBinding>> list() async {
    final file = await _configFile();
    if (!await file.exists()) return <FolderBinding>[];
    final raw = await file.readAsString();
    final obj = jsonDecode(raw) as Map<String, dynamic>;
    return ((obj['bindings'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(FolderBinding.fromJson)
        .toList();
  }

  Future<void> _saveAll(List<FolderBinding> bindings) async {
    final file = await _configFile();
    await file.writeAsString(jsonEncode(<String, dynamic>{
      'bindings': [for (final b in bindings) b.toJson()],
    }));
  }

  Future<FolderBinding> add({
    required String label,
    required String external,
    String space = StoreSpace.files,
    required String folder,
    List<String> ignore = const [],
  }) async {
    if (space != StoreSpace.files && space != StoreSpace.artifacts) {
      throw ArgumentError('bindings support files/artifacts spaces');
    }
    final normFolder = normalizeStorePath(folder.isEmpty ? 'bind' : folder);
    final binding = FolderBinding(
      id: 'b-${_uuid.v4().substring(0, 8)}',
      label: label,
      external: external,
      space: space,
      folder: normFolder,
      ignore: ignore,
      createdAt: DateTime.now(),
    );
    final all = await list();
    all.add(binding);
    await _saveAll(all);
    if (_autoSyncStarted) await _rewatch();
    return binding;
  }

  Future<void> remove(String id) async {
    final all = await list();
    all.removeWhere((b) => b.id == id);
    await _saveAll(all);
    if (_autoSyncStarted) await _rewatch();
  }

  Future<BindingSyncReport> syncOne(FolderBinding binding) async {
    final report = BindingSyncReport(binding.id);
    final external = Directory(binding.external);
    if (!await external.exists()) {
      report.errors.add('external dir not found: ${binding.external}');
      return report;
    }
    final store = await StoreService.instance.localStore();
    final device = await DeviceIdentity.deviceId();
    final indexFile = await _indexFile(binding.id);
    final index = await _loadIndex(indexFile);

    final seen = <String>{};
    await for (final item in _walk(external, binding.ignore)) {
      final rel = item.rel;
      seen.add(rel);
      final stat = await item.file.stat();
      final size = stat.size;
      final mtime = stat.modified.millisecondsSinceEpoch;
      final prev = index[rel];
      if (prev != null &&
          prev['size'] == size &&
          prev['mtime'] == mtime) {
        report.skipped++;
        continue;
      }
      final sha = await _sha256File(item.file);
      if (prev != null && prev['sha'] == sha && prev['size'] == size) {
        report.skipped++;
        continue;
      }
      final destRel =
          binding.folder.isEmpty ? rel : '${binding.folder}/$rel';
      try {
        await _ingest(store, device, binding.space, destRel, item.file, size, sha);
        index[rel] = <String, dynamic>{
          'sha': sha,
          'size': size,
          'mtime': mtime,
        };
        if (prev == null) {
          report.added++;
        } else {
          report.updated++;
        }
      } catch (e) {
        report.errors.add('$rel: $e');
      }
    }

    for (final rel in index.keys.toList()) {
      if (seen.contains(rel)) continue;
      final destRel =
          binding.folder.isEmpty ? rel : '${binding.folder}/$rel';
      try {
        await store.delete(device, binding.space, destRel);
        index.remove(rel);
        report.deleted++;
      } catch (e) {
        report.errors.add('delete $rel: $e');
      }
    }
    await indexFile.writeAsString(jsonEncode(index));
    return report;
  }

  Future<List<BindingSyncReport>> syncAll() async {
    final reports = <BindingSyncReport>[];
    for (final b in await list()) {
      reports.add(await syncOne(b));
    }
    return reports;
  }

  /// 轮询式周期同步（兜底；优先用 [startAutoSync]）。
  Future<void Function()> startPeriodic(Duration interval) async {
    final timer = Timer.periodic(interval, (_) {
      unawaited(syncAll());
    });
    return () => timer.cancel();
  }

  /// 事件驱动（DirectoryWatcher 去抖）+ 低频周期兜底。幂等可重复调用。
  Future<void> startAutoSync({
    Duration periodic = const Duration(minutes: 2),
    Duration debounce = const Duration(seconds: 2),
  }) async {
    await stopAutoSync();
    _autoSyncStarted = true;
    _stopPeriodic = await startPeriodic(periodic);
    await _rewatch(debounce: debounce);
    unawaited(syncAll());
  }

  Future<void> stopAutoSync() async {
    _autoSyncStarted = false;
    _stopPeriodic?.call();
    _stopPeriodic = null;
    for (final t in _debounceByBinding.values) {
      t.cancel();
    }
    _debounceByBinding.clear();
    for (final s in _watchSubs) {
      await s.cancel();
    }
    _watchSubs.clear();
  }

  Future<void> _rewatch({
    Duration debounce = const Duration(seconds: 2),
  }) async {
    for (final s in _watchSubs) {
      await s.cancel();
    }
    _watchSubs.clear();
    for (final b in await list()) {
      final dir = Directory(b.external);
      if (!await dir.exists()) continue;
      try {
        final w = DirectoryWatcher(b.external);
        _watchSubs.add(w.events.listen((_) {
          _debounceByBinding[b.id]?.cancel();
          _debounceByBinding[b.id] = Timer(debounce, () {
            unawaited(syncOne(b));
          });
        }));
      } catch (_) {
        // Unsupported platform / permission — periodic sync still covers it.
      }
    }
  }

  // ── 内部 ─────────────────────────────────────────────

  Future<Map<String, Map<String, dynamic>>> _loadIndex(File f) async {
    if (!await f.exists()) return <String, Map<String, dynamic>>{};
    final raw = await f.readAsString();
    final obj = jsonDecode(raw) as Map<String, dynamic>;
    return obj.map((k, v) => MapEntry(
        k, ((v as Map).cast<String, dynamic>())));
  }

  Stream<({String rel, File file})> _walk(
      Directory dir, List<String> ignore) async* {
    await for (final ent in dir.list(followLinks: false)) {
      final name = p.basename(ent.path);
      if (name.startsWith('.')) continue;
      if (_matchesIgnore(name, ignore)) continue;
      final type = await FileSystemEntity.type(ent.path, followLinks: false);
      if (type == FileSystemEntityType.link) continue;
      if (ent is Directory) {
        yield* _walk(ent, ignore);
      } else if (ent is File) {
        final rel = p.relative(ent.path, from: dir.path);
        yield (rel: rel, file: ent);
      }
    }
  }

  bool _matchesIgnore(String name, List<String> ignore) {
    for (final pat in ignore) {
      if (pat == name) return true;
      if (pat.startsWith('*') && name.endsWith(pat.substring(1))) return true;
      if (pat.endsWith('*') && name.startsWith(pat.substring(0, pat.length - 1))) {
        return true;
      }
    }
    return false;
  }

  Future<String> _sha256File(File f) async {
    final digest = await crypto.sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  Future<void> _ingest(
    LocalStore store,
    String device,
    String space,
    String destRel,
    File file,
    int size,
    String sha,
  ) async {
    final (uid, _) = await store.writeBegin(
      deviceId: device,
      space: space,
      path: destRel,
      size: size,
      sha256: sha,
    );
    final raf = await file.open();
    try {
      var offset = 0;
      final buf = Uint8List(math.min(LocalStore.maxReadChunk, 64 * 1024));
      while (true) {
        final n = await raf.readInto(buf);
        if (n <= 0) break;
        await store.writeChunk(device, space, uid, offset, buf.sublist(0, n));
        offset += n;
      }
    } finally {
      await raf.close();
    }
    final (committed, failed) = await store.commit(device, space, <String>[uid]);
    if (failed.isNotEmpty) {
      throw StateError('binding commit failed: $failed');
    }
  }
}

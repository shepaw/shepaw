import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 队列中的变更条目（docs/storage_protocol_spec.md §6.1）。
class SyncQueueEntry {
  SyncQueueEntry({
    required this.seq,
    required this.kind,
    required this.space,
    this.files,
    this.path,
    required this.createdMs,
  });

  final int seq;

  /// 'commit' | 'delete'
  final String kind;
  final String space;

  /// commit：整批文件清单。
  final List<({String path, int size, String sha256})>? files;

  /// delete：目标路径（可为目录）。
  final String? path;
  final int createdMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'seq': seq,
        'kind': kind,
        'space': space,
        if (files != null)
          'files': [
            for (final f in files!)
              {'path': f.path, 'size': f.size, 'sha256': f.sha256},
          ],
        if (path != null) 'path': path,
        'created_ms': createdMs,
      };

  static SyncQueueEntry fromJson(Map<String, dynamic> json) => SyncQueueEntry(
        seq: json['seq'] as int,
        kind: json['kind'] as String,
        space: json['space'] as String,
        files: (json['files'] as List?)
            ?.map((f) => (
                  path: f['path'] as String,
                  size: f['size'] as int,
                  sha256: f['sha256'] as String,
                ))
            .toList(),
        path: json['path'] as String?,
        createdMs: json['created_ms'] as int? ?? 0,
      );
}

/// 变更日志（本机设备目录的 change_seq 与未同步队列的唯一事实源）。
///
/// LocalStore 在 commit/delete 成功路径上**同步内联**调用 append——
/// 不存在"落盘成功但漏记队列"的窗口。只记录 [ownerDeviceId] 自己的变更
/// （master 代远端转正不计入本机队列）。持久化于
/// `<store>/.system/sync_queue.json` 与 `sync_state.json`。
class SyncJournal {
  SyncJournal({required Directory storeRoot, required this.ownerDeviceId})
      : _queueFile = File(p.join(storeRoot.path, '.system', 'sync_queue.json')),
        _stateFile = File(p.join(storeRoot.path, '.system', 'sync_state.json')),
        _recentFile =
            File(p.join(storeRoot.path, '.system', 'sync_recent.json'));

  final String ownerDeviceId;
  final File _queueFile;
  final File _stateFile;
  final File _recentFile;

  /// 追加成功后的回调（SyncEngine 设为 poke，本地写后立即触发同步）。
  static void Function()? onAppended;

  /// 队列或水位变化（append / dequeue / 清空）后的回调，供 UI 刷新。
  static void Function()? onChanged;

  static const pendingDisplayLimit = 200;

  /// 「最近」Tab 保留的变更文件上限（出队后仍在）。
  static const recentLimit = 200;

  Future<void>? _appendLock;
  List<SyncQueueEntry>? _queue;
  int? _changeSeq;
  int? _ackSeq;
  List<SyncRecentFile>? _recent;

  /// 是否已从磁盘读到过 `sync_recent.json`（缺文件时需从队列种子）。
  bool _recentFromDisk = false;
  bool _recentLoaded = false;

  // ────────────────────────────── 持久化 ──

  Future<List<SyncQueueEntry>> _loadQueue() async {
    final cached = _queue;
    if (cached != null) return cached;
    if (!await _queueFile.exists()) return _queue = <SyncQueueEntry>[];
    try {
      final decoded = jsonDecode(await _queueFile.readAsString()) as List;
      return _queue = decoded
          .map((e) =>
              SyncQueueEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return _queue = <SyncQueueEntry>[];
    }
  }

  Future<void> _saveQueue() async {
    await _queueFile.parent.create(recursive: true);
    final tmp = File('${_queueFile.path}.tmp');
    await tmp
        .writeAsString(jsonEncode([for (final e in _queue!) e.toJson()]));
    await tmp.rename(_queueFile.path);
  }

  Future<(int, int)> _loadState() async {
    if (_changeSeq != null && _ackSeq != null) {
      return (_changeSeq!, _ackSeq!);
    }
    if (await _stateFile.exists()) {
      try {
        final decoded = jsonDecode(await _stateFile.readAsString())
            as Map<String, dynamic>;
        _changeSeq = decoded['change_seq'] as int? ?? 0;
        _ackSeq = decoded['ack_seq'] as int? ?? 0;
      } catch (_) {
        _changeSeq = 0;
        _ackSeq = 0;
      }
    } else {
      _changeSeq = 0;
      _ackSeq = 0;
    }
    return (_changeSeq!, _ackSeq!);
  }

  Future<void> _saveState() async {
    await _stateFile.parent.create(recursive: true);
    final tmp = File('${_stateFile.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({'change_seq': _changeSeq, 'ack_seq': _ackSeq}));
    await tmp.rename(_stateFile.path);
  }

  Future<List<SyncRecentFile>> _loadRecent() async {
    if (_recentLoaded) return _recent!;
    _recentLoaded = true;
    if (!await _recentFile.exists()) {
      _recentFromDisk = false;
      return _recent = <SyncRecentFile>[];
    }
    try {
      final decoded = jsonDecode(await _recentFile.readAsString());
      final raw = decoded is Map
          ? decoded['files'] as List? ?? const []
          : decoded is List
              ? decoded
              : const [];
      _recentFromDisk = true;
      return _recent = [
        for (final e in raw)
          if (e is Map)
            SyncRecentFile.fromJson(Map<String, dynamic>.from(e)),
      ];
    } catch (_) {
      _recentFromDisk = false;
      return _recent = <SyncRecentFile>[];
    }
  }

  Future<void> _saveRecent() async {
    await _recentFile.parent.create(recursive: true);
    final tmp = File('${_recentFile.path}.tmp');
    await tmp.writeAsString(jsonEncode({
      'files': [for (final e in _recent!) e.toJson()],
    }));
    await tmp.rename(_recentFile.path);
    _recentFromDisk = true;
  }

  void _capRecent() {
    final list = _recent;
    if (list == null || list.length <= recentLimit) return;
    _recent = list.sublist(0, recentLimit);
  }

  void _upsertRecent(String space, String path, int size, int mtimeMs,
      {String sha256 = ''}) {
    final list = _recent ??= <SyncRecentFile>[];
    list.removeWhere((e) => e.space == space && e.path == path);
    list.insert(
      0,
      SyncRecentFile(
        space: space,
        path: path,
        size: size,
        mtimeMs: mtimeMs,
        sha256: sha256,
      ),
    );
    _capRecent();
  }

  void _removeRecent(String space, String path) {
    final list = _recent;
    if (list == null || list.isEmpty) return;
    list.removeWhere((e) =>
        e.space == space && (e.path == path || e.path.startsWith('$path/')));
  }

  void _rebuildRecentFromQueue(List<SyncQueueEntry> entries) {
    final byKey = <String, SyncRecentFile>{};
    final order = <String>[];
    String keyOf(String space, String path) => '$space\u0000$path';
    for (final e in entries) {
      if (e.kind == 'delete') {
        final path = e.path ?? '';
        final prefix = '$path/';
        final drop = byKey.keys
            .where((k) {
              final sep = k.indexOf('\u0000');
              if (sep < 0) return false;
              if (k.substring(0, sep) != e.space) return false;
              final pth = k.substring(sep + 1);
              return pth == path || pth.startsWith(prefix);
            })
            .toList();
        for (final k in drop) {
          byKey.remove(k);
          order.remove(k);
        }
      } else {
        for (final f in e.files ??
            const <({String path, int size, String sha256})>[]) {
          final key = keyOf(e.space, f.path);
          byKey[key] = SyncRecentFile(
            space: e.space,
            path: f.path,
            size: f.size,
            mtimeMs: e.createdMs,
            sha256: f.sha256,
          );
          order.remove(key);
          order.add(key);
        }
      }
    }
    _recent = [
      for (final k in order.reversed)
        if (byKey[k] != null) byKey[k]!,
    ];
    _capRecent();
  }

  Future<void> _syncRecentAfterAppendLocked({
    required String kind,
    required String space,
    List<({String path, int size, String sha256})>? files,
    String? path,
    required int createdMs,
  }) async {
    await _loadRecent();
    if (!_recentFromDisk) {
      _rebuildRecentFromQueue(await _loadQueue());
    } else if (kind == 'delete') {
      _removeRecent(space, path ?? '');
    } else {
      for (final f
          in files ?? const <({String path, int size, String sha256})>[]) {
        _upsertRecent(space, f.path, f.size, createdMs, sha256: f.sha256);
      }
    }
    await _saveRecent();
  }

  /// 串行化 append（并发 commit/delete 的 seq 分配不竞争）。
  Future<T> _locked<T>(Future<T> Function() action) {
    final prev = _appendLock ?? Future.value();
    final completer = Completer<T>();
    _appendLock = prev.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  // ────────────────────────────── 公开 API ──

  /// 本机 commit 成功后的日志追加（LocalStore 内联调用）。
  /// 返回分配的 seq；非本机设备的变更（master 代远端转正）忽略返回 0。
  Future<int> appendCommit(String deviceId, String space,
      List<({String path, int size, String sha256})> files) async {
    if (deviceId != ownerDeviceId) return 0;
    return _locked(() async {
      await _loadState();
      _changeSeq = _changeSeq! + 1;
      final entry = SyncQueueEntry(
        seq: _changeSeq!,
        kind: 'commit',
        space: space,
        files: List.of(files),
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );
      (await _loadQueue()).add(entry);
      await _saveQueue();
      await _saveState();
      await _syncRecentAfterAppendLocked(
        kind: 'commit',
        space: space,
        files: entry.files,
        createdMs: entry.createdMs,
      );
      onAppended?.call();
      onChanged?.call();
      return entry.seq;
    });
  }

  /// 本机 delete 成功后的日志追加。
  Future<int> appendDelete(String deviceId, String space, String path) async {
    if (deviceId != ownerDeviceId) return 0;
    return _locked(() async {
      await _loadState();
      _changeSeq = _changeSeq! + 1;
      final entry = SyncQueueEntry(
        seq: _changeSeq!,
        kind: 'delete',
        space: space,
        path: path,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      );
      (await _loadQueue()).add(entry);
      await _saveQueue();
      await _saveState();
      await _syncRecentAfterAppendLocked(
        kind: 'delete',
        space: space,
        path: path,
        createdMs: entry.createdMs,
      );
      onAppended?.call();
      onChanged?.call();
      return entry.seq;
    });
  }

  /// 出队（master 已确认 applied_seq ≥ seq）并推进 ack 水位。
  Future<void> dequeueThrough(int seq) async {
    await _locked(() async {
      final queue = await _loadQueue();
      queue.removeWhere((e) => e.seq <= seq);
      if (_ackSeq == null || seq > _ackSeq!) _ackSeq = seq;
      await _saveQueue();
      await _saveState();
      onChanged?.call();
    });
  }

  /// 将 ack 回退到 [seq]（master applied 落后于本地 ack 时的自愈）。
  /// 不改 change_seq；不清空队列。
  Future<void> resetAckTo(int seq) async {
    await _locked(() async {
      await _loadState();
      if (seq < 0) seq = 0;
      if (_ackSeq != null && seq < _ackSeq!) {
        _ackSeq = seq;
        await _saveState();
      }
    });
  }

  Future<List<SyncQueueEntry>> pending() async =>
      List.of(await _loadQueue());

  /// 清空待同步队列，**保留** change_seq / ack_seq（危险区 wipe 后继续写不撞 master 游标）。
  Future<void> clearPendingQueue() async {
    await _locked(() async {
      await _loadState();
      _queue = <SyncQueueEntry>[];
      await _saveQueue();
      await _saveState();
      onChanged?.call();
    });
  }

  Future<({int changeSeq, int ackSeq})> cursors() async {
    final (c, a) = await _loadState();
    return (changeSeq: c, ackSeq: a);
  }

  Future<int> pendingCount() async => (await _loadQueue()).length;

  /// 最近变更的文件（commit 落盘即记，master 出队后仍保留；delete 会移除）。
  ///
  /// 若 `sync_recent.json` 尚不存在（升级前只写了队列），从当前 pending 队列种子。
  Future<List<SyncRecentFile>> recent({int limit = recentLimit}) async {
    return _locked(() async {
      await _loadRecent();
      if (!_recentFromDisk) {
        _rebuildRecentFromQueue(await _loadQueue());
        await _saveRecent();
      }
      final list = List<SyncRecentFile>.of(_recent ?? const []);
      if (limit < list.length) return list.sublist(0, limit);
      return list;
    });
  }

  Future<int> pendingBytes() async {
    var total = 0;
    for (final e in await _loadQueue()) {
      if (e.files != null) {
        for (final f in e.files!) {
          total += f.size;
        }
      }
    }
    return total;
  }
}

/// 「最近」Tab 用的已落盘变更文件（不含 delete）。
class SyncRecentFile {
  const SyncRecentFile({
    required this.space,
    required this.path,
    required this.size,
    required this.mtimeMs,
    this.sha256 = '',
  });

  final String space;
  final String path;
  final int size;
  final int mtimeMs;
  final String sha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'space': space,
        'path': path,
        'size': size,
        'mtime_ms': mtimeMs,
        if (sha256.isNotEmpty) 'sha256': sha256,
      };

  static SyncRecentFile fromJson(Map<String, dynamic> json) => SyncRecentFile(
        space: json['space'] as String? ?? '',
        path: json['path'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        mtimeMs: (json['mtime_ms'] as num?)?.toInt() ??
            (json['created_ms'] as num?)?.toInt() ??
            0,
        sha256: json['sha256'] as String? ?? '',
      );
}

/// 队列条目展开后的单文件/单路径行（commit 的 `files[]` 拆开，delete 一行）。
class SyncPendingItem {
  const SyncPendingItem({
    required this.seq,
    required this.kind,
    required this.space,
    required this.path,
    required this.size,
    required this.createdMs,
  });

  final int seq;

  /// 'commit' | 'delete'
  final String kind;
  final String space;
  final String path;
  final int size;
  final int createdMs;
}

/// 把 journal 条目展开成 UI 行；[limit] 默认 [SyncJournal.pendingDisplayLimit]。
List<SyncPendingItem> expandSyncPending(
  List<SyncQueueEntry> entries, {
  int limit = SyncJournal.pendingDisplayLimit,
}) {
  final out = <SyncPendingItem>[];
  for (final e in entries) {
    if (e.kind == 'delete') {
      out.add(SyncPendingItem(
        seq: e.seq,
        kind: 'delete',
        space: e.space,
        path: e.path ?? '',
        size: 0,
        createdMs: e.createdMs,
      ));
    } else {
      for (final f in e.files ?? const <({String path, int size, String sha256})>[]) {
        out.add(SyncPendingItem(
          seq: e.seq,
          kind: 'commit',
          space: e.space,
          path: f.path,
          size: f.size,
          createdMs: e.createdMs,
        ));
        if (out.length >= limit) return out;
      }
    }
    if (out.length >= limit) return out;
  }
  return out;
}

int countExpandedPending(List<SyncQueueEntry> entries) {
  var n = 0;
  for (final e in entries) {
    if (e.kind == 'delete') {
      n++;
    } else {
      n += e.files?.length ?? 0;
    }
  }
  return n;
}

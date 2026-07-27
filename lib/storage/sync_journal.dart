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
        _stateFile = File(p.join(storeRoot.path, '.system', 'sync_state.json'));

  final String ownerDeviceId;
  final File _queueFile;
  final File _stateFile;

  /// 追加成功后的回调（SyncEngine 设为 poke，本地写后立即触发同步）。
  static void Function()? onAppended;

  Future<void>? _appendLock;
  List<SyncQueueEntry>? _queue;
  int? _changeSeq;
  int? _ackSeq;

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
      onAppended?.call();
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
      onAppended?.call();
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
    });
  }

  Future<({int changeSeq, int ackSeq})> cursors() async {
    final (c, a) = await _loadState();
    return (changeSeq: c, ackSeq: a);
  }

  Future<int> pendingCount() async => (await _loadQueue()).length;

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

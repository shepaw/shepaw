import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../peer/services/peer_connection.dart'
    show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'sync_journal.dart';

/// master 传输抽象（测试中进程内仿真；真机走 StoreService.call）。
abstract class SyncTransport {
  Future<bool> get isMasterOnline;
  Future<Map<String, dynamic>?> call(StoreFrame frame);
}

/// 同步引擎（docs/storage_protocol_spec.md §6，M4）。
///
/// 把本机 `<device_id>/*` 的变更（SyncJournal 队列）按 seq 顺序送达 master：
/// 文件内容走 write.begin/chunk，**commit 标记最后送达**；master 返回
/// applied_seq 后推进本地 ack 水位并出队。master 不可达时本地完整可用，
/// 上线后按游标差量重放。master 是本机时本地条目即视为已应用。
class SyncEngine {
  SyncEngine();
  static final SyncEngine instance = SyncEngine();

  static const _tag = 'SyncEngine';
  static const _heartbeat = Duration(seconds: 30);

  final _log = LoggerService();
  SyncJournal? _journal;
  LocalStore? _store;
  String? _deviceId;
  SyncTransport? _transport;
  Future<String> Function()? _masterDeviceIdFn;
  Timer? _timer;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  bool _syncing = false;

  bool get started => _journal != null;

  SyncJournal? get journal => _journal;

  /// 启动（app_bootstrap，StoreService.start 之后）。
  /// [autoSync] 为 false 时不自动触发同步（测试手动驱动 syncNow）。
  Future<void> start({
    required Directory storeRoot,
    required LocalStore store,
    required SyncTransport transport,
    required Future<String> Function() masterDeviceIdFn,
    bool autoSync = true,
  }) async {
    if (_journal != null) return;
    _deviceId = await DeviceIdentity.deviceId();
    _store = store;
    _journal = SyncJournal(storeRoot: storeRoot, ownerDeviceId: _deviceId!);
    _transport = transport;
    _masterDeviceIdFn = masterDeviceIdFn;
    // LocalStore 变更的唯一挂接点（覆盖快照等直写路径）
    LocalStore.syncJournal = _journal;

    if (autoSync) {
      // 本地写后立即触发一轮同步（不等心跳）
      SyncJournal.onAppended = poke;
      _timer = Timer.periodic(_heartbeat, (_) => unawaited(syncNow()));
      // master 上线即触发一轮
      _eventSub = PeerConnectionManager.instance.events.listen((event) {
        if (event.type == PeerConnectionEventType.connected) {
          unawaited(_onPeerConnected(event.peerId));
        }
      });
      unawaited(syncNow());
    }
    _log.info('SyncEngine started', tag: _tag);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _eventSub?.cancel();
    _eventSub = null;
    LocalStore.syncJournal = null;
    SyncJournal.onAppended = null;
  }

  Future<void> _onPeerConnected(String peerId) async {
    try {
      final master = await _masterDeviceIdFn!();
      final peers = await PeerStorageService().loadAllPeers();
      final peer = peers.where((p) => p.id == peerId).firstOrNull;
      if (peer != null && peer.fingerprint == master) {
        unawaited(syncNow());
      }
    } catch (_) {}
  }

  /// 追加后立即触发（本地写路径调用）。
  void poke() => unawaited(syncNow());

  // ────────────────────────────── 上传主循环 ──

  /// 单航班同步：master 可达时按游标差量重放。
  Future<void> syncNow() async {
    final journal = _journal;
    final transport = _transport;
    if (journal == null || transport == null || _syncing) return;
    _syncing = true;
    try {
      // master 是本机：本地变更即已应用，直接按 change_seq 出队
      final master = await _masterDeviceIdFn!();
      if (master == _deviceId) {
        final cursors = await journal.cursors();
        if (cursors.changeSeq > 0) {
          await journal.dequeueThrough(cursors.changeSeq);
        }
        return;
      }
      if (!await transport.isMasterOnline) return;

      // 对账（spec §6.2）
      final hello = await transport.call(StoreFrame(
          op: StoreOp.syncHello,
          payload: {'device': _deviceId}));
      if (hello == null || hello.containsKey('_error')) return;
      final applied = hello['applied_seq'] as int? ?? 0;

      final pending = await journal.pending();
      for (final entry in pending) {
        if (entry.seq <= applied) {
          // master 已应用（如重连前已送达）→ 直接出队
          await journal.dequeueThrough(entry.seq);
          continue;
        }
        final ok = entry.kind == 'commit'
            ? await _uploadCommit(entry)
            : await _uploadDelete(entry);
        if (!ok) break; // 保序：失败留队，下轮重试
        await journal.dequeueThrough(entry.seq);
      }
    } catch (e, st) {
      _log.warning('syncNow failed: $e', tag: _tag);
      _log.debug('$st', tag: _tag);
    } finally {
      _syncing = false;
    }
  }

  /// commit 条目：逐文件 write.begin/chunk 上传，commit 标记最后送达。
  Future<bool> _uploadCommit(SyncQueueEntry entry) async {
    final transport = _transport!;
    final uploadIds = <String>[];
    for (final file in entry.files!) {
      // 读本地正式区内容上传
      final local = await _readLocalAll(entry.space, file.path, file.size);
      if (local == null) {
        // 本地已被清理（如 GFS 剪掉的快照，随后的 delete 条目会覆盖）→ 跳过
        _log.warning('local file gone, skip upload: ${file.path}', tag: _tag);
        continue;
      }
      final begin = await transport.call(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': entry.space,
            'path': file.path,
            'size': file.size,
            'sha256': file.sha256,
          }));
      if (begin == null || begin.containsKey('_error')) {
        _log.warning('write.begin failed for ${file.path}: ${begin?['_error']}',
            tag: _tag);
        return false;
      }
      final uploadId = begin['upload_id'] as String;
      var offset = begin['received'] as int? ?? 0;
      while (offset < local.length) {
        final end = (offset + LocalStore.maxReadChunk) > local.length
            ? local.length
            : offset + LocalStore.maxReadChunk;
        final chunk = await transport.call(StoreFrame(
            op: StoreOp.writeChunk,
            payload: {
              'space': entry.space,
              'upload_id': uploadId,
              'offset': offset,
              'data': base64Encode(
                  Uint8List.fromList(local.sublist(offset, end))),
            }));
        if (chunk == null || chunk.containsKey('_error')) return false;
        offset = chunk['received'] as int? ?? end;
      }
      uploadIds.add(uploadId);
    }
    // commit 标记最后送达（spec §6.2）
    final res = await transport.call(StoreFrame(
        op: StoreOp.commit,
        payload: {
          'space': entry.space,
          'upload_ids': uploadIds,
          'upto_seq': entry.seq,
        }));
    if (res == null || res.containsKey('_error')) return false;
    final failed = (res['failed'] as List?) ?? const [];
    if (failed.isNotEmpty) {
      _log.warning('master commit failed: $failed', tag: _tag);
      return false;
    }
    return true;
  }

  Future<bool> _uploadDelete(SyncQueueEntry entry) async {
    final res = await _transport!.call(StoreFrame(
        op: StoreOp.delete,
        payload: {
          'space': entry.space,
          'path': entry.path,
          'upto_seq': entry.seq,
        }));
    return res != null && !res.containsKey('_error');
  }

  Future<Uint8List?> _readLocalAll(
      String space, String relPath, int size) async {
    final store = _store!;
    final deviceId = _deviceId!;
    try {
      final builder = BytesBuilder(copy: false);
      var offset = 0;
      while (offset < size) {
        final (chunk, _, eof) = await store.read(
            deviceId, space, relPath, offset, LocalStore.maxReadChunk);
        if (chunk.isEmpty && size > 0) return null;
        builder.add(chunk);
        offset += chunk.length;
        if (eof) break;
      }
      final bytes = builder.toBytes();
      if (bytes.length != size) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// 真机传输：经 StoreService 到 master。
class StoreServiceTransport implements SyncTransport {
  StoreServiceTransport(this._callFn, this._masterOnlineFn);

  final Future<Map<String, dynamic>?> Function(StoreFrame frame) _callFn;
  final Future<bool> Function() _masterOnlineFn;

  @override
  Future<bool> get isMasterOnline => _masterOnlineFn();

  @override
  Future<Map<String, dynamic>?> call(StoreFrame frame) => _callFn(frame);
}

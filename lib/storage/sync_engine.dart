import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../peer/services/peer_connection.dart'
    show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'master_migration_service.dart';
import 'store_protocol.dart';
import 'sync_journal.dart';

/// master 传输抽象（测试中进程内仿真；真机走 StoreService.call）。
abstract class SyncTransport {
  Future<bool> get isMasterOnline;
  Future<Map<String, dynamic>?> call(StoreFrame frame);
}

/// 待同步快照（备份与恢复页 / 清单 UI）。
class SyncStatus {
  const SyncStatus({
    this.pending = const [],
    this.pendingCount = 0,
    this.pendingBytes = 0,
    this.isSyncing = false,
    this.uploadingSeq,
    this.masterIsSelf = true,
    this.masterOnline = true,
    this.lastError,
  });

  static const empty = SyncStatus();

  final List<SyncQueueEntry> pending;
  final int pendingCount;
  final int pendingBytes;
  final bool isSyncing;
  final int? uploadingSeq;
  final bool masterIsSelf;
  final bool masterOnline;

  /// 最近一次 syncNow 失败原因（错误码或短句）；成功清空队列后为 null。
  final String? lastError;

  bool get hasPending => pendingCount > 0;

  /// 源设备：master 在远端且（有队列或正在传）时展示待同步卡。
  bool get showPendingCard => !masterIsSelf && (hasPending || isSyncing);

  List<SyncPendingItem> get items => expandSyncPending(pending);

  int get expandedCount => countExpandedPending(pending);
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
  /// 经 peer 控制帧上传时小于 LocalStore.maxReadChunk，避免 base64 后撑爆通道。
  static const _syncChunk = 32 * 1024;

  final _log = LoggerService();
  SyncJournal? _journal;
  LocalStore? _store;
  String? _deviceId;
  SyncTransport? _transport;
  Future<String> Function()? _masterDeviceIdFn;
  Timer? _timer;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  bool _syncing = false;
  int? _uploadingSeq;
  String? _lastError;
  Future<void>? _syncFlight;
  final _statusController = StreamController<SyncStatus>.broadcast();
  SyncStatus _latestStatus = SyncStatus.empty;

  bool get started => _journal != null;

  SyncJournal? get journal => _journal;

  Stream<SyncStatus> get status => _statusController.stream;

  SyncStatus get latestStatus => _latestStatus;

  /// 待同步到 master 的队列条目数（未启动则为 0）。
  Future<int> pendingCount() async =>
      (await _journal?.pendingCount()) ?? 0;

  /// 待同步字节估算。
  Future<int> pendingBytes() async =>
      (await _journal?.pendingBytes()) ?? 0;

  Future<SyncStatus> currentStatus() async {
    await _emitStatus();
    return _latestStatus;
  }

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

    SyncJournal.onChanged = () => unawaited(_emitStatus());
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
    unawaited(_emitStatus());
    _log.info('SyncEngine started', tag: _tag);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _eventSub?.cancel();
    _eventSub = null;
    LocalStore.syncJournal = null;
    SyncJournal.onAppended = null;
    SyncJournal.onChanged = null;
    _journal = null;
    _syncing = false;
    _uploadingSeq = null;
    _lastError = null;
    _syncFlight = null;
    _latestStatus = SyncStatus.empty;
  }

  Future<void> _onPeerConnected(String peerId) async {
    try {
      final peers = await PeerStorageService().loadAllPeers();
      final peer = peers.where((p) => p.id == peerId).firstOrNull;
      if (peer == null || peer.trustLevel != TrustLevel.owner) return;

      // 任意 owner 上线：先 query 指针（离线端醒来改指，§6.5 / spec §10.2）
      try {
        final q = await MasterMigrationService.instance
            .queryPointer(peer.fingerprint);
        if (q != null) {
          await MasterMigrationService.instance.applyPointer(
            masterId: q.master,
            epoch: q.epoch,
            fromDeviceId: peer.fingerprint,
          );
        }
      } catch (_) {}
      final masterNow = await _masterDeviceIdFn!();
      if (peer.fingerprint == masterNow) {
        unawaited(syncNow());
      }
    } catch (_) {}
  }

  /// 追加后立即触发（本地写路径调用）。
  void poke() => unawaited(syncNow());

  Future<void> _emitStatus() async {
    final journal = _journal;
    if (journal == null) {
      _latestStatus = SyncStatus.empty;
      if (!_statusController.isClosed) _statusController.add(_latestStatus);
      return;
    }
    final pending = await journal.pending();
    var bytes = 0;
    for (final e in pending) {
      if (e.files != null) {
        for (final f in e.files!) {
          bytes += f.size;
        }
      }
    }
    var masterIsSelf = true;
    var masterOnline = true;
    try {
      final master = await _masterDeviceIdFn?.call();
      masterIsSelf = master == null || master == _deviceId;
      masterOnline = masterIsSelf || (await _transport?.isMasterOnline ?? false);
    } catch (_) {}
    _latestStatus = SyncStatus(
      pending: pending,
      pendingCount: pending.length,
      pendingBytes: bytes,
      isSyncing: _syncing,
      uploadingSeq: _uploadingSeq,
      masterIsSelf: masterIsSelf,
      masterOnline: masterOnline,
      lastError: _lastError,
    );
    if (!_statusController.isClosed) _statusController.add(_latestStatus);
  }

  // ────────────────────────────── 上传主循环 ──

  /// 单航班同步：master 可达时按游标差量重放。
  /// 已在同步中时加入当前航班（避免「立即同步」被静默丢掉）。
  Future<void> syncNow() {
    final flight = _syncFlight;
    if (flight != null) return flight;
    final started = _syncNowBody();
    _syncFlight = started;
    return started.whenComplete(() {
      if (identical(_syncFlight, started)) _syncFlight = null;
    });
  }

  Future<void> _syncNowBody() async {
    final journal = _journal;
    final transport = _transport;
    if (journal == null || transport == null) return;
    _syncing = true;
    _uploadingSeq = null;
    await _emitStatus();
    try {
      // master 是本机：本地变更即已应用，直接按 change_seq 出队
      final master = await _masterDeviceIdFn!();
      if (master == _deviceId) {
        final cursors = await journal.cursors();
        if (cursors.changeSeq > 0) {
          await journal.dequeueThrough(cursors.changeSeq);
        }
        _lastError = null;
        return;
      }
      if (!await transport.isMasterOnline) {
        _lastError = StoreError.masterOffline;
        _log.warning('syncNow skipped: master offline', tag: _tag);
        return;
      }

      // 对账（spec §6.2）
      final hello = await transport.call(StoreFrame(
          op: StoreOp.syncHello,
          payload: {'device': _deviceId}));
      if (hello == null || hello.containsKey('_error')) {
        _lastError = hello?['_error'] as String? ?? StoreError.masterOffline;
        _log.warning('sync.hello failed: $_lastError', tag: _tag);
        return;
      }
      final applied = _asInt(hello['applied_seq']) ?? 0;
      final local = await journal.cursors();

      // B2：master applied 落后于本地 ack → 回退 ack，并重推本地正式区差量
      if (applied < local.ackSeq) {
        _log.warning(
            'heal: master applied_seq=$applied < local ack=${local.ackSeq}',
            tag: _tag);
        await journal.resetAckTo(applied);
        await _reconcileLocalToMaster(applied);
      }

      final pending = await journal.pending();
      for (final entry in pending) {
        if (entry.seq <= applied) {
          // master 已应用（如重连前已送达）→ 直接出队
          await journal.dequeueThrough(entry.seq);
          continue;
        }
        _uploadingSeq = entry.seq;
        await _emitStatus();
        final ok = entry.kind == 'commit'
            ? await _uploadCommit(entry)
            : await _uploadDelete(entry);
        if (!ok) break; // 保序：失败留队，下轮重试
        await journal.dequeueThrough(entry.seq);
      }
      if ((await journal.pendingCount()) == 0) {
        _lastError = null;
      }
    } catch (e, st) {
      _lastError = '$e';
      _log.warning('syncNow failed: $e', tag: _tag);
      _log.debug('$st', tag: _tag);
    } finally {
      _syncing = false;
      _uploadingSeq = null;
      await _emitStatus();
    }
  }

  /// commit 条目：逐文件 write.begin/chunk 上传，commit 标记最后送达。
  Future<bool> _uploadCommit(SyncQueueEntry entry) async {
    final transport = _transport!;
    final uploadIds = <String>[];
    for (final file in entry.files!) {
      // 读本地正式区当前内容上传。声明哈希必须与实际上传字节一致：
      // 队列里的 sha256/size 可能已过期（入队后文件被覆盖/GFS/绑定同步等），
      // 若仍按旧声明上传，master commit 会稳定返回 hash_mismatch 并卡死队列。
      final local = await _readLocalAll(entry.space, file.path);
      if (local == null) {
        // 本地已被清理（如 GFS 剪掉的快照，随后的 delete 条目会覆盖）→ 跳过
        _log.warning('local file gone, skip upload: ${file.path}', tag: _tag);
        continue;
      }
      final sha = crypto.sha256.convert(local).toString();
      if (sha != file.sha256 || local.length != file.size) {
        _log.warning(
          'stale journal meta for ${file.path}: '
          'queued size=${file.size} sha=${file.sha256} → '
          'actual size=${local.length} sha=$sha',
          tag: _tag,
        );
      }
      final begin = await transport.call(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': entry.space,
            'path': file.path,
            'size': local.length,
            'sha256': sha,
          }));
      if (begin == null || begin.containsKey('_error')) {
        _lastError = begin?['_error'] as String? ?? StoreError.internal;
        _log.warning(
            'write.begin failed for ${file.path}: $_lastError',
            tag: _tag);
        return false;
      }
      final uploadId = begin['upload_id'] as String;
      var offset = _asInt(begin['received']) ?? 0;
      while (offset < local.length) {
        final end = (offset + _syncChunk) > local.length
            ? local.length
            : offset + _syncChunk;
        final chunk = await transport.call(StoreFrame(
            op: StoreOp.writeChunk,
            payload: {
              'space': entry.space,
              'upload_id': uploadId,
              'offset': offset,
              'data': base64Encode(
                  Uint8List.fromList(local.sublist(offset, end))),
            }));
        if (chunk == null || chunk.containsKey('_error')) {
          _lastError = chunk?['_error'] as String? ?? StoreError.internal;
          _log.warning(
              'write.chunk failed for ${file.path} offset=$offset: $_lastError',
              tag: _tag);
          return false;
        }
        offset = _asInt(chunk['received']) ?? end;
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
    if (res == null || res.containsKey('_error')) {
      _lastError = res?['_error'] as String? ?? StoreError.internal;
      return false;
    }
    final failed = (res['failed'] as List?) ?? const [];
    if (failed.isNotEmpty) {
      _lastError = 'commit failed: $failed';
      _log.warning('master commit failed: $failed', tag: _tag);
      return false;
    }
    _lastError = null;
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
    if (res == null) {
      _lastError = StoreError.masterOffline;
      return false;
    }
    final err = res['_error'];
    // 幂等：已删除 / 本就不存在 → 视为成功（重放不死锁）
    if (err == StoreError.notFound) {
      _lastError = null;
      return true;
    }
    if (res.containsKey('_error')) {
      _lastError = err as String? ?? StoreError.internal;
      return false;
    }
    _lastError = null;
    return true;
  }

  /// master applied 落后时：按 hash 对账本机正式区并差量重推。
  Future<void> _reconcileLocalToMaster(int appliedSeq) async {
    final store = _store;
    final deviceId = _deviceId;
    final transport = _transport;
    final journal = _journal;
    if (store == null || deviceId == null || transport == null || journal == null) {
      return;
    }
    for (final space in StoreSpace.all) {
      final entries = await store.list(deviceId, space);
      for (final e in entries) {
        final meta = await transport.call(StoreFrame(
          op: StoreOp.meta,
          payload: {
            'space': space,
            'device': deviceId,
            'path': e.path,
          },
        ));
        final remoteSha = meta?['sha256'] as String?;
        if (meta != null &&
            !meta.containsKey('_error') &&
            remoteSha == e.sha256) {
          continue;
        }
        // 缺或 hash 不一致 → 重新入队（新 seq），稍后按序上传
        await journal.appendCommit(deviceId, space, [
          (path: e.path, size: e.size, sha256: e.sha256),
        ]);
      }
    }
  }

  /// 读本地正式区当前全文（不依赖队列里可能过期的 size）。
  Future<Uint8List?> _readLocalAll(String space, String relPath) async {
    final store = _store!;
    final deviceId = _deviceId!;
    try {
      final builder = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, _, eof) = await store.read(
            deviceId, space, relPath, offset, _syncChunk);
        if (chunk.isEmpty) {
          if (offset == 0 && !eof) return null;
          break;
        }
        builder.add(chunk);
        offset += chunk.length;
        if (eof) break;
      }
      return builder.toBytes();
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

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

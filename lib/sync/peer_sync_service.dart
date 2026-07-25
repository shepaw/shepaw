import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../peer/models/paired_peer.dart';
import '../peer/services/peer_connection.dart'
    show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'sync_frame.dart';
import 'sync_roles.dart';
import 'sync_store.dart';
import 'sync_tables.dart';

/// 同步进度事件（配对进度页 / 存储管理页共用数据源）。
class SyncProgressEvent {
  SyncProgressEvent({
    required this.stage,
    this.peerId,
    this.detail,
    this.progress,
  });

  final String stage;
  final String? peerId;
  final String? detail;

  /// 0..1，无法度量时为 null。
  final double? progress;

  static const stageRoleNegotiated = 'role_negotiated';
  static const stageAdopting = 'adopting';
  static const stageSnapshotSync = 'snapshot_sync';
  static const stageActive = 'active';
  static const stageError = 'error';
}

/// hub 侧一台 console 的快照发送会话（流控见 spec §7 snapshot.next）。
class _SnapshotSender {
  _SnapshotSender({
    required this.file,
    required this.totalChunks,
    required this.watermark,
  });

  final File file;
  final int totalChunks;
  final int watermark;
  RandomAccessFile? _raf;

  Future<List<int>> readChunk(int index) async {
    _raf ??= await file.open();
    await _raf!.setPosition(index * PeerSyncService.snapshotChunkSize);
    return _raf!.read(PeerSyncService.snapshotChunkSize);
  }

  Future<void> dispose() async {
    await _raf?.close();
    if (await file.exists()) await file.delete();
  }
}

/// console 侧的快照接收会话。
class _SnapshotReceiver {
  _SnapshotReceiver({
    required this.tempFile,
    required this.snapshotId,
    required this.watermark,
    required this.sha256Hex,
    required this.totalChunks,
  });

  final File tempFile;
  final String snapshotId;
  final int watermark;
  final String sha256Hex;
  final int totalChunks;
  RandomAccessFile? raf;
  int expectedChunk = 0;

  Future<void> dispose() async {
    await raf?.close();
    if (await tempFile.exists()) await tempFile.delete();
  }
}

/// 主从同步编排服务（docs/sync_protocol_spec.md）。
///
/// 职责：
/// - 配对完成后落地角色（onPairingEstablished）：hub 激活时钟/触发器，
///   console 写游标并进入配对状态机；
/// - sync.* 帧路由（复用 PeerConnection 控制帧，不侵入聊天逻辑）；
/// - hub 侧：hello→驱动 adopt/快照、pull→changes、ack→设备游标、stats；
/// - console 侧：hello 上报、adopt 导出、快照接收导入、changes 落库回执、
///   notify/心跳驱动的 pull 循环。
class PeerSyncService {
  PeerSyncService._();
  static final PeerSyncService instance = PeerSyncService._();

  static const _tag = 'PeerSync';
  static const snapshotChunkSize = 64 * 1024;
  static const _pullLimit = 500;
  static const _adoptBatchSize = 500;

  final _log = LoggerService();
  final _manager = PeerConnectionManager.instance;
  final _peerStorage = PeerStorageService();

  bool _started = false;
  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _eventSub;
  Timer? _notifyTimer;
  Timer? _pullHeartbeat;
  int _lastBroadcastSeq = -1;

  /// hub 运行时状态
  SyncStore? _hubStore;
  final Map<String, Map<String, int>> _adoptMergeCounts = {};
  final Map<String, _SnapshotSender> _snapshotSenders = {};

  /// console 运行时状态
  _SnapshotReceiver? _snapshotReceiver;
  bool _pullInFlight = false;
  Completer<Map<String, dynamic>>? _statsCompleter;

  final _progressController =
      StreamController<SyncProgressEvent>.broadcast();

  /// 同步进度流（UI 订阅）。
  Stream<SyncProgressEvent> get progressEvents => _progressController.stream;

  Future<SyncStore> _store() async =>
      SyncStore(await LocalDatabaseService().database);

  void _progress(String stage,
      {String? peerId, String? detail, double? progress}) {
    _progressController.add(SyncProgressEvent(
        stage: stage, peerId: peerId, detail: detail, progress: progress));
  }

  // ═════════════════════════════════════════════════════════════════════
  // 生命周期
  // ═════════════════════════════════════════════════════════════════════

  /// App 启动时调用（app_bootstrap）。幂等。
  Future<void> start() async {
    if (_started) return;
    _started = true;
    _controlSub = _manager.controlEvents.listen(_onControl);
    _eventSub = _manager.events.listen(_onConnectionEvent);

    // 恢复角色：本机是某些 peer 的 hub → 确保时钟/触发器/notify 轮询就位；
    // 本机是 console → 确保触发器摘除 + 心跳 pull。
    final peers = await _peerStorage.loadAllPeers();
    final store = await _store();
    if (peers.any((p) =>
        p.syncEnabled && p.deviceRole == SyncDeviceRole.console.name)) {
      await store.activateHub();
      _hubStore = store;
      _startNotifyPoller();
    }
    if (peers.any(
        (p) => p.syncEnabled && p.deviceRole == SyncDeviceRole.hub.name)) {
      _startPullHeartbeat();
    }
    _log.info('PeerSyncService started', tag: _tag);
  }

  Future<void> stop() async {
    _started = false;
    await _controlSub?.cancel();
    await _eventSub?.cancel();
    _notifyTimer?.cancel();
    _pullHeartbeat?.cancel();
    for (final s in _snapshotSenders.values) {
      await s.dispose();
    }
    _snapshotSenders.clear();
    await _snapshotReceiver?.dispose();
    _snapshotReceiver = null;
  }

  // ═════════════════════════════════════════════════════════════════════
  // 角色落地（配对完成后由 PeerPairingService 调用）
  // ═════════════════════════════════════════════════════════════════════

  /// 配对确立主从角色后的落地动作。
  Future<void> onPairingEstablished(
      PairedPeer peer, RoleDecision decision) async {
    final store = await _store();
    switch (decision.localRole) {
      case SyncDeviceRole.hub:
        await store.activateHub();
        _hubStore = store;
        await store.upsertDevice(peer.id,
            state: SyncCursorState.stateRoleNegotiated);
        _startNotifyPoller();
        _progress(SyncProgressEvent.stageRoleNegotiated, peerId: peer.id);
        _log.info('role established: local=hub peer=${peer.deviceName}',
            tag: _tag);
      case SyncDeviceRole.console:
        // §4.1：已绑定过其他 hub → 清空本机副本并重新走初始同步。
        final cursor = await store.cursorState();
        if (cursor.hubPeerId != null && cursor.hubPeerId != peer.id) {
          _log.warning(
              'rebinding to new hub ${peer.id} (was ${cursor.hubPeerId}), clearing replica',
              tag: _tag);
          await store.clearBusinessTables();
        } else if (cursor.hubPeerId == peer.id &&
            cursor.state == SyncCursorState.stateActive) {
          // 与同一 hub 重复配对：增量同步仍有效，不重置状态机，
          // 避免副本数据被整轮 adopt/快照重灌。
          _log.info('re-paired with same hub, keep active sync', tag: _tag);
          return;
        }
        await store.writeCursor(
          hubPeerId: peer.id,
          lastAppliedSeq: 0,
          state: SyncCursorState.stateRoleNegotiated,
        );
        _startPullHeartbeat();
        _progress(SyncProgressEvent.stageRoleNegotiated, peerId: peer.id);
        _log.info('role established: local=console hub=${peer.deviceName}',
            tag: _tag);
      case SyncDeviceRole.none:
        break;
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  // 帧路由
  // ═════════════════════════════════════════════════════════════════════

  void _onControl(PeerControlEvent event) {
    if (event.type != kSyncControlType) return;
    final SyncFrame frame;
    try {
      frame = SyncFrame.tryParse(event.data) ??
          (throw const FormatException('not a sync frame'));
    } on FormatException catch (e) {
      _log.warning('malformed sync frame from ${event.peerId}: $e', tag: _tag);
      return;
    }
    _handleFrame(event.peerId, frame).catchError((Object e, StackTrace st) {
      _log.error('sync frame ${frame.op} handling failed',
          tag: _tag, error: e, stackTrace: st);
      _progress(SyncProgressEvent.stageError,
          peerId: event.peerId, detail: '${frame.op}: $e');
    });
  }

  Future<void> _handleFrame(String peerId, SyncFrame frame) async {
    if (!frame.versionSupported) {
      await _sendError(peerId, frame,
          code: SyncErrorCode.unsupportedVersion,
          message: 'local protocol v$kSyncProtocolVersion');
      return;
    }
    // M1 epoch 恒为 1（spec §1：epoch fencing 在 M6 启用）。
    if (frame.epoch != 1) {
      await _sendError(peerId, frame, code: SyncErrorCode.epochMismatch);
      return;
    }

    final peer = await _peerStorage.getPeerById(peerId);
    if (peer == null || !peer.syncEnabled) {
      await _sendError(peerId, frame, code: SyncErrorCode.notPaired);
      return;
    }

    // 按本机角色分发：paired_peers.device_role 记录的是【对端】角色。
    if (peer.deviceRole == SyncDeviceRole.console.name) {
      await _handleFrameAsHub(peerId, frame);
    } else if (peer.deviceRole == SyncDeviceRole.hub.name) {
      await _handleFrameAsConsole(peerId, frame);
    } else {
      await _sendError(peerId, frame, code: SyncErrorCode.roleInvalid);
    }
  }

  Future<void> _handleFrameAsHub(String peerId, SyncFrame frame) async {
    final store = _hubStore ??= await _store();
    switch (frame.op) {
      case SyncOp.hello:
        await _hubOnHello(peerId, frame, store);
      case SyncOp.pull:
        await _hubOnPull(peerId, frame, store);
      case SyncOp.ack:
        final cursor = frame.payload['cursor'] as int? ?? 0;
        await store.updateDeviceAck(peerId, cursor);
      case SyncOp.adoptBatch:
        await _hubOnAdoptBatch(peerId, frame, store);
      case SyncOp.snapshotNext:
        await _hubOnSnapshotNext(peerId, frame);
      case SyncOp.snapshotDone:
        final watermark = frame.payload['applied_seq'] as int? ?? 0;
        await store.upsertDevice(peerId,
            lastAckSeq: watermark, state: SyncCursorState.stateActive);
        final sender = _snapshotSenders.remove(peerId);
        await sender?.dispose();
        _progress(SyncProgressEvent.stageActive, peerId: peerId);
      case SyncOp.stats:
        await _hubOnStatsQuery(peerId, store);
      default:
        _log.warning('hub: unexpected op ${frame.op}', tag: _tag);
    }
  }

  Future<void> _handleFrameAsConsole(String peerId, SyncFrame frame) async {
    final store = await _store();
    // console 只接受绑定 hub 的帧（spec §9）。
    final cursor = await store.cursorState();
    if (cursor.hubPeerId != null && cursor.hubPeerId != peerId) {
      await _sendError(peerId, frame, code: SyncErrorCode.roleInvalid,
          message: 'bound to another hub');
      return;
    }
    switch (frame.op) {
      case SyncOp.adoptBegin:
        await _consoleOnAdoptBegin(peerId, frame, store);
      case SyncOp.adoptDone:
        await _consoleOnAdoptDone(peerId, store);
      case SyncOp.snapshotBegin:
        await _consoleOnSnapshotBegin(peerId, frame);
      case SyncOp.snapshotChunk:
        await _consoleOnSnapshotChunk(peerId, frame, store);
      case SyncOp.changes:
        await _consoleOnChanges(peerId, frame, store);
      case SyncOp.notify:
        await _consolePull(peerId);
      case SyncOp.stats:
        if (frame.payload['kind'] == 'report') {
          final completer = _statsCompleter;
          _statsCompleter = null;
          completer?.complete(Map<String, dynamic>.from(frame.payload));
        }
      case SyncOp.error:
        _log.warning('hub error: ${frame.payload}', tag: _tag);
        _progress(SyncProgressEvent.stageError,
            peerId: peerId, detail: '${frame.payload['message']}');
      default:
        _log.warning('console: unexpected op ${frame.op}', tag: _tag);
    }
  }

  Future<void> _send(String peerId, SyncFrame frame) async {
    final ok = await _manager.sendControl(peerId, frame.toJson());
    if (!ok) {
      throw StateError('send ${frame.op} to $peerId failed (not connected)');
    }
  }

  Future<void> _sendError(String peerId, SyncFrame ref,
      {required String code, String? message}) async {
    await _manager.sendControl(
        peerId,
        syncErrorFrame(
                epoch: frameEpoch, refOp: ref.op, code: code, message: message)
            .toJson());
  }

  /// M1 epoch 恒为 1。
  static const int frameEpoch = 1;

  // ═════════════════════════════════════════════════════════════════════
  // hub 侧处理器
  // ═════════════════════════════════════════════════════════════════════

  /// console 上报本地状态，hub 据此驱动 adopt/快照/增量（spec §4 hello）。
  Future<void> _hubOnHello(
      String peerId, SyncFrame frame, SyncStore store) async {
    final state = frame.payload['state'] as String? ?? '';
    final hasLocalData = frame.payload['has_local_data'] as bool? ?? false;
    _log.info('hello from $peerId: state=$state hasLocalData=$hasLocalData',
        tag: _tag);

    switch (state) {
      case SyncCursorState.stateRoleNegotiated:
        if (hasLocalData) {
          await store.updateDeviceState(peerId, SyncCursorState.stateAdopting);
          _adoptMergeCounts[peerId] = <String, int>{};
          await _send(
              peerId,
              SyncFrame(op: SyncOp.adoptBegin, epoch: frameEpoch, payload: {
                'tables': kSyncTables.map((t) => t.name).toList(),
              }));
          _progress(SyncProgressEvent.stageAdopting, peerId: peerId);
        } else {
          await store.updateDeviceState(
              peerId, SyncCursorState.stateSnapshotSync);
          unawaited(_hubSendSnapshot(peerId, store));
        }
      case SyncCursorState.stateAdopting:
        // 断线恢复：归并幂等，重新发起。
        await store.updateDeviceState(peerId, SyncCursorState.stateAdopting);
        _adoptMergeCounts[peerId] = <String, int>{};
        await _send(
            peerId,
            SyncFrame(op: SyncOp.adoptBegin, epoch: frameEpoch, payload: {
              'tables': kSyncTables.map((t) => t.name).toList(),
            }));
        _progress(SyncProgressEvent.stageAdopting, peerId: peerId);
      case SyncCursorState.stateSnapshotSync:
        unawaited(_hubSendSnapshot(peerId, store));
      case SyncCursorState.stateActive:
        // 正常增量循环，console 会自行 pull。
        break;
      default:
        _log.warning('hello with unknown state: $state', tag: _tag);
    }
  }

  Future<void> _hubOnPull(
      String peerId, SyncFrame frame, SyncStore store) async {
    if (_snapshotSenders.containsKey(peerId)) {
      await _sendError(peerId, frame,
          code: SyncErrorCode.busy, message: 'snapshot in flight');
      return;
    }
    final cursor = frame.payload['cursor'] as int? ?? 0;
    final limit =
        (frame.payload['limit'] as int? ?? _pullLimit).clamp(1, 2000);
    final page = await store.changesSince(cursor: cursor, limit: limit);
    await _send(
        peerId,
        SyncFrame(op: SyncOp.changes, epoch: frameEpoch, payload: {
          'from': page.fromSeq,
          'to': page.toSeq,
          'tables': page.tablesPayload(),
          'has_more': page.hasMore,
        }));
  }

  Future<void> _hubOnAdoptBatch(
      String peerId, SyncFrame frame, SyncStore store) async {
    final table = frame.payload['table'] as String;
    final rows = (frame.payload['rows'] as List)
        .map((r) => ((r as Map)['row'] as Map).cast<String, Object?>())
        .toList();
    final (ins, upd, skip) = await store.mergeAdoptBatch(table, rows);
    final counts = _adoptMergeCounts.putIfAbsent(peerId, () => <String, int>{});
    counts[table] = (counts[table] ?? 0) + ins + upd;
    _log.debug(
        'adopt.batch $table from $peerId: +$ins ~$upd =$skip', tag: _tag);

    if (frame.payload['last'] == true) {
      await store.updateDeviceState(
          peerId, SyncCursorState.stateSnapshotSync);
      final merged = _adoptMergeCounts.remove(peerId) ?? <String, int>{};
      await _send(
          peerId,
          SyncFrame(
              op: SyncOp.adoptDone,
              epoch: frameEpoch,
              payload: {'merged': merged}));
      _log.info('adopt done for $peerId: $merged', tag: _tag);
    }
  }

  /// 生成快照并发送 begin 帧；chunk 由 snapshot.next 流控驱动（spec §7）。
  Future<void> _hubSendSnapshot(String peerId, SyncStore store) async {
    // 先取水位再 VACUUM：快照内容 ⊇ {seq ≤ watermark}，console 从水位增量，
    // 重叠部分靠 INSERT OR REPLACE 幂等吸收（spec §7 规则）。
    final watermark = await store.currentSeq();
    final dir = await getTemporaryDirectory();
    final snapshotId = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File(p.join(dir.path, 'shepaw_snapshot_$snapshotId.db'));
    final db = await LocalDatabaseService().database;
    // VACUUM INTO 的参数绑定在不同 SQLite 版本行为不一，直接内联可信路径。
    final escaped = file.path.replaceAll("'", "''");
    await db.execute("VACUUM INTO '$escaped'");

    final bytes = await file.length();
    final digest = await crypto.sha256.bind(file.openRead()).first;
    final totalChunks = (bytes / snapshotChunkSize).ceil();
    _snapshotSenders[peerId] =
        _SnapshotSender(file: file, totalChunks: totalChunks, watermark: watermark);

    await _send(
        peerId,
        SyncFrame(op: SyncOp.snapshotBegin, epoch: frameEpoch, payload: {
          'snapshot_id': snapshotId,
          'seq_watermark': watermark,
          'db_bytes': bytes,
          'sha256': digest.toString(),
        }));
    _progress(SyncProgressEvent.stageSnapshotSync,
        peerId: peerId, detail: 'snapshot ${bytes ~/ 1024}KB', progress: 0);
  }

  Future<void> _hubOnSnapshotNext(String peerId, SyncFrame frame) async {
    final sender = _snapshotSenders[peerId];
    if (sender == null) return;
    final index = frame.payload['chunk_no'] as int? ?? -1;
    if (index < 0 || index >= sender.totalChunks) {
      // 最后一块已被确认后 console 会发 done；越界序号忽略。
      return;
    }
    final data = await sender.readChunk(index);
    final isLast = index == sender.totalChunks - 1;
    await _send(
        peerId,
        SyncFrame(op: SyncOp.snapshotChunk, epoch: frameEpoch, payload: {
          'chunk_no': index,
          'last': isLast,
          'data': base64Encode(data),
        }));
    _progress(SyncProgressEvent.stageSnapshotSync,
        peerId: peerId, progress: (index + 1) / sender.totalChunks);
    if (isLast) {
      // 发送完毕，等 console 的 snapshot.done；临时文件在 done/断连时清理。
      await sender._raf?.close();
    }
  }

  Future<void> _hubOnStatsQuery(String peerId, SyncStore store) async {
    final report = await hubStatsReport(store);
    report['kind'] = 'report';
    await _send(peerId,
        SyncFrame(op: SyncOp.stats, epoch: frameEpoch, payload: report));
  }

  /// hub 统计（管理页 + stats 帧共用）。
  Future<Map<String, dynamic>> hubStatsReport(SyncStore store) async {
    final watermark = await store.currentSeq();
    final devices = await store.devices();
    final peers = await _peerStorage.loadAllPeers();
    final peerNames = {for (final p in peers) p.id: p.deviceName};
    return <String, dynamic>{
      'db_bytes': await store.dbBytes(),
      'seq_watermark': watermark,
      'devices': [
        for (final d in devices)
          <String, dynamic>{
            'peer_id': d.peerId,
            'name': peerNames[d.peerId] ?? d.peerId,
            'role': 'console',
            'state': d.state,
            'last_ack_seq': d.lastAckSeq,
            'lag': watermark - d.lastAckSeq,
            'last_seen': d.updatedAtMs,
            'online': _manager.connectedPeerIds.contains(d.peerId),
          },
      ],
    };
  }

  void _startNotifyPoller() {
    if (_notifyTimer != null) return;
    _notifyTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _pollNotify());
  }

  Future<void> _pollNotify() async {
    try {
      final store = _hubStore;
      if (store == null) return;
      final seq = await store.currentSeq();
      if (_lastBroadcastSeq < 0) {
        _lastBroadcastSeq = seq;
        return;
      }
      if (seq <= _lastBroadcastSeq) return;
      _lastBroadcastSeq = seq;
      final devices = await store.devices();
      for (final d in devices) {
        if (d.state != SyncCursorState.stateActive) continue;
        if (!_manager.connectedPeerIds.contains(d.peerId)) continue;
        await _manager.sendControl(
            d.peerId,
            SyncFrame(
                    op: SyncOp.notify,
                    epoch: frameEpoch,
                    payload: {'latest': seq})
                .toJson());
      }
    } catch (e) {
      _log.warning('notify poll failed: $e', tag: _tag);
    }
  }

  // ═════════════════════════════════════════════════════════════════════
  // console 侧处理器
  // ═════════════════════════════════════════════════════════════════════

  void _onConnectionEvent(PeerConnectionEvent event) {
    if (event.type == PeerConnectionEventType.connected) {
      unawaited(_consoleOnConnected(event.peerId));
    } else if (event.type == PeerConnectionEventType.disconnected) {
      // 断连清理 hub 侧发送会话；console 侧接收会话保留状态，
      // 重连后经 hello(state=snapshot_sync) 由 hub 重新发起。
      final sender = _snapshotSenders.remove(event.peerId);
      sender?.dispose();
      _adoptMergeCounts.remove(event.peerId);
    }
  }

  /// 连接建立：若对方是绑定 hub，上报本地状态机阶段（spec §4 hello）。
  Future<void> _consoleOnConnected(String peerId) async {
    final peer = await _peerStorage.getPeerById(peerId);
    if (peer == null ||
        !peer.syncEnabled ||
        peer.deviceRole != SyncDeviceRole.hub.name) {
      return;
    }
    final store = await _store();
    final cursor = await store.cursorState();
    if (cursor.hubPeerId != peerId) return;

    switch (cursor.state) {
      case SyncCursorState.stateActive:
        await _consolePull(peerId);
      default:
        final hasData = await store.hasLocalBusinessData();
        await _send(
            peerId,
            SyncFrame(op: SyncOp.hello, epoch: frameEpoch, payload: {
              'state': cursor.state,
              'cursor': cursor.lastAppliedSeq,
              'has_local_data': hasData,
            }));
    }
  }

  /// 导出本地数据逐表上送（spec §6）。每批 ≤ _adoptBatchSize 行。
  Future<void> _consoleOnAdoptBegin(
      String peerId, SyncFrame frame, SyncStore store) async {
    await store.writeCursor(state: SyncCursorState.stateAdopting);
    _progress(SyncProgressEvent.stageAdopting, peerId: peerId);
    final tables = (frame.payload['tables'] as List).cast<String>();
    for (var ti = 0; ti < tables.length; ti++) {
      final table = tables[ti];
      final rows = await store.exportTable(table);
      final isLastTable = ti == tables.length - 1;
      if (rows.isEmpty) {
        if (isLastTable) {
          await _send(
              peerId,
              SyncFrame(op: SyncOp.adoptBatch, epoch: frameEpoch, payload: {
                'table': table,
                'batch_no': 0,
                'last': true,
                'rows': <Map<String, dynamic>>[],
              }));
        }
        continue;
      }
      for (var start = 0; start < rows.length; start += _adoptBatchSize) {
        final batchRows = rows.sublist(
            start,
            (start + _adoptBatchSize) > rows.length
                ? rows.length
                : start + _adoptBatchSize);
        final isLastBatch =
            isLastTable && start + _adoptBatchSize >= rows.length;
        await _send(
            peerId,
            SyncFrame(op: SyncOp.adoptBatch, epoch: frameEpoch, payload: {
              'table': table,
              'batch_no': start ~/ _adoptBatchSize,
              'last': isLastBatch,
              'rows': [
                for (final row in batchRows)
                  <String, dynamic>{
                    'updated_at':
                        syncTableByName(table).updatedAtMsOf(row),
                    'row': row,
                  },
              ],
            }));
        _progress(SyncProgressEvent.stageAdopting,
            peerId: peerId,
            detail: '$table ${start + batchRows.length}/${rows.length}',
            progress: (ti + (start + batchRows.length) / rows.length) /
                tables.length);
      }
    }
    _log.info('adopt export finished', tag: _tag);
  }

  /// 归并完成：先导出本地备份（7 天保留），再清库，进入 snapshot_sync。
  Future<void> _consoleOnAdoptDone(String peerId, SyncStore store) async {
    await _exportAdoptBackup();
    await store.clearBusinessTables();
    await store.writeCursor(
        lastAppliedSeq: 0, state: SyncCursorState.stateSnapshotSync);
    _progress(SyncProgressEvent.stageSnapshotSync, peerId: peerId);
    _log.info('local tables cleared, waiting for snapshot', tag: _tag);
    // hub 收到 adopt.done 前已把状态置为 snapshot_sync；快照由 hub 主动发起，
    // 这里无需回复，等待 snapshot.begin。
  }

  /// console 清库前的本地备份（spec §6：保留 7 天）。
  Future<void> _exportAdoptBackup() async {
    try {
      final store = await _store();
      final dir = await getApplicationDocumentsDirectory();
      final backupDir = Directory(p.join(dir.path, 'sync_adopt_backups'));
      await backupDir.create(recursive: true);
      // 清理过期备份
      final expiry = DateTime.now().subtract(const Duration(days: 7));
      await for (final f in backupDir.list()) {
        if (f is File &&
            f.path.endsWith('.json') &&
            (await f.lastModified()).isBefore(expiry)) {
          await f.delete();
        }
      }
      final ts = DateTime.now().millisecondsSinceEpoch;
      final file = File(p.join(backupDir.path, 'adopt_backup_$ts.json'));
      final data = <String, dynamic>{};
      for (final table in kSyncTables) {
        data[table.name] = await store.exportTable(table.name);
      }
      await file.writeAsString(jsonEncode(data));
      _log.info('adopt backup written: ${file.path}', tag: _tag);
    } catch (e) {
      _log.warning('adopt backup failed (non-fatal): $e', tag: _tag);
    }
  }

  Future<void> _consoleOnSnapshotBegin(String peerId, SyncFrame frame) async {
    await _snapshotReceiver?.dispose();
    final dir = await getTemporaryDirectory();
    final tempFile = File(p.join(
        dir.path, 'shepaw_inbound_${frame.payload['snapshot_id']}.db.part'));
    if (await tempFile.exists()) await tempFile.delete();
    final receiver = _SnapshotReceiver(
      tempFile: tempFile,
      snapshotId: frame.payload['snapshot_id'] as String,
      watermark: frame.payload['seq_watermark'] as int,
      sha256Hex: frame.payload['sha256'] as String,
      totalChunks: ((frame.payload['db_bytes'] as int? ?? 0) /
              PeerSyncService.snapshotChunkSize)
          .ceil(),
    );
    receiver.raf = await tempFile.open(mode: FileMode.write);
    _snapshotReceiver = receiver;
    final store = await _store();
    await store.writeCursor(state: SyncCursorState.stateSnapshotSync);
    _progress(SyncProgressEvent.stageSnapshotSync, peerId: peerId, progress: 0);
    await _requestNextChunk(peerId, 0);
  }

  Future<void> _requestNextChunk(String peerId, int index) async {
    await _send(
        peerId,
        SyncFrame(op: SyncOp.snapshotNext, epoch: frameEpoch, payload: {
          'chunk_no': index,
        }));
  }

  Future<void> _consoleOnSnapshotChunk(
      String peerId, SyncFrame frame, SyncStore store) async {
    final receiver = _snapshotReceiver;
    if (receiver == null) return;
    final index = frame.payload['chunk_no'] as int;
    if (index != receiver.expectedChunk) {
      _log.warning(
          'snapshot chunk out of order: got $index want ${receiver.expectedChunk}',
          tag: _tag);
      return; // 等 hub 按 next 重发（M1 不做乱序缓存）
    }
    final data = base64Decode(frame.payload['data'] as String);
    await receiver.raf!.writeFrom(data);
    receiver.expectedChunk++;

    if (frame.payload['last'] == true) {
      await receiver.raf!.close();
      receiver.raf = null;
      // 整体校验（spec §7）
      final digest =
          await crypto.sha256.bind(receiver.tempFile.openRead()).first;
      if (digest.toString() != receiver.sha256Hex) {
        _log.warning('snapshot sha256 mismatch, discard', tag: _tag);
        await receiver.dispose();
        _snapshotReceiver = null;
        _progress(SyncProgressEvent.stageError,
            peerId: peerId, detail: 'snapshot checksum mismatch');
        return; // 状态机停在 snapshot_sync，重连后 hub 重发
      }
      await store.importSnapshotTables(
          receiver.tempFile.path, receiver.watermark);
      await store.writeCursor(hubPeerId: peerId); // 确保绑定关系落库
      await receiver.dispose();
      _snapshotReceiver = null;
      await _send(
          peerId,
          SyncFrame(op: SyncOp.snapshotDone, epoch: frameEpoch, payload: {
            'snapshot_id': receiver.snapshotId,
            'applied_seq': receiver.watermark,
          }));
      _progress(SyncProgressEvent.stageActive, peerId: peerId, progress: 1);
      _log.info(
          'snapshot imported, watermark=${receiver.watermark}', tag: _tag);
      // 追平快照后可能落后的增量
      await _consolePull(peerId);
      return;
    }
    _progress(SyncProgressEvent.stageSnapshotSync,
        peerId: peerId,
        progress: receiver.totalChunks == 0
            ? null
            : receiver.expectedChunk / receiver.totalChunks,
        detail: 'chunk ${receiver.expectedChunk}/${receiver.totalChunks}');
    await _requestNextChunk(peerId, receiver.expectedChunk);
  }

  Future<void> _consoleOnChanges(
      String peerId, SyncFrame frame, SyncStore store) async {
    final tables = SyncChangeEntry.parseTablesPayload(
        (frame.payload['tables'] as Map).cast<String, dynamic>());
    final to = frame.payload['to'] as int? ?? 0;
    await store.applyChangesPayload(tables, to);
    await _send(
        peerId,
        SyncFrame(
            op: SyncOp.ack, epoch: frameEpoch, payload: {'cursor': to}));
    if (frame.payload['has_more'] == true) {
      await _consolePull(peerId);
    }
  }

  Future<void> _consolePull(String peerId) async {
    if (_pullInFlight) return;
    _pullInFlight = true;
    try {
      final store = await _store();
      final cursor = await store.cursorState();
      if (cursor.state != SyncCursorState.stateActive) return;
      await _send(
          peerId,
          SyncFrame(op: SyncOp.pull, epoch: frameEpoch, payload: {
            'cursor': cursor.lastAppliedSeq,
            'limit': _pullLimit,
          }));
    } finally {
      _pullInFlight = false;
    }
  }

  /// console 向绑定 hub 查询统计（spec §8，管理页数据源）。
  /// hub 不在线或未绑定时返回 null。
  Future<Map<String, dynamic>?> queryHubStats({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final store = await _store();
    final cursor = await store.cursorState();
    final hubId = cursor.hubPeerId;
    if (hubId == null) return null;
    if (!_manager.connectedPeerIds.contains(hubId)) return null;
    _statsCompleter = Completer<Map<String, dynamic>>();
    await _manager.sendControl(
        hubId,
        SyncFrame(
                op: SyncOp.stats, epoch: frameEpoch, payload: {'kind': 'query'})
            .toJson());
    return _statsCompleter!.future.then((m) => m as Map<String, dynamic>?).timeout(
        timeout, onTimeout: () => null);
  }

  void _startPullHeartbeat() {
    _pullHeartbeat ??=
        Timer.periodic(const Duration(seconds: 30), (_) async {
      try {
        final store = await _store();
        final cursor = await store.cursorState();
        final hubId = cursor.hubPeerId;
        if (hubId == null) return;
        if (!_manager.connectedPeerIds.contains(hubId)) return;
        if (cursor.state == SyncCursorState.stateActive) {
          await _consolePull(hubId);
        }
      } catch (e) {
        _log.warning('pull heartbeat failed: $e', tag: _tag);
      }
    });
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';

/// 存储空间编排服务（docs/storage_protocol_spec.md v1，M2）。
///
/// - master 指针（KV 持久化，默认本机）与 loopback 入口；
/// - 客户端调用：master 是本机 → loopback；否则经 peer 控制帧远程调用；
/// - master 侧：处理入站 store 帧——trust_level 强制（friend 拒绝+审计）、
///   调用者身份 = 配对指纹（写路径收敛的锚点）。
class StoreService {
  StoreService._();
  static final StoreService instance = StoreService._();

  static const _tag = 'Store';
  static const _auditTag = 'StoreAudit';
  static const _masterKey = 'storage.master_device_id';
  static const _callTimeout = Duration(seconds: 15);

  final _log = LoggerService();
  final _manager = PeerConnectionManager.instance;
  final _peerStorage = PeerStorageService();
  final _uuid = const Uuid();

  LocalStore? _store;
  StreamSubscription<PeerControlEvent>? _controlSub;
  final _pending = <String, Completer<Map<String, dynamic>?>>{};

  // ────────────────────────────── 生命周期 ──

  Future<void> start() async {
    _controlSub ??= _manager.controlEvents.listen(_onControl);
    final store = await _localStore();
    final removed = await store.gcStaging();
    if (removed > 0) {
      _log.info('gc staging: removed $removed stale sessions', tag: _tag);
    }
  }

  Future<void> stop() async {
    await _controlSub?.cancel();
    _controlSub = null;
  }

  Future<LocalStore> _localStore() async {
    final existing = _store;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docs.path, 'shepaw', 'store'));
    await root.create(recursive: true);
    return _store = LocalStore(root: root);
  }

  // ────────────────────────────── master 指针 ──

  /// 当前 master 的 device_id（默认本机，M6 支持指定/迁移）。
  Future<String> masterDeviceId() async {
    final db = LocalDatabaseService();
    final stored = await db.getUserValue(_masterKey);
    if (stored != null && stored.isNotEmpty) return stored;
    return DeviceIdentity.deviceId();
  }

  Future<void> setMasterDeviceId(String deviceId) async {
    final db = LocalDatabaseService();
    await db.setUserValue(_masterKey, deviceId);
  }

  Future<bool> isMaster() async =>
      await masterDeviceId() == await DeviceIdentity.deviceId();

  // ────────────────────────────── 客户端调用 ──

  /// 客户端 API：向 master 发请求并等结果。master 是本机时走 loopback。
  Future<Map<String, dynamic>?> call(StoreFrame frame) async {
    final self = await DeviceIdentity.deviceId();
    if (await masterDeviceId() == self) {
      return _dispatch(frame,
          callerDeviceId: self,
          trustLevel: TrustLevel.owner,
          loopback: true);
    }
    // 远端 master：经配对通道发送（M4 起叠加本地优先队列）
    final masterId = await masterDeviceId();
    final peers = await _peerStorage.loadAllPeers();
    final masterPeer =
        peers.where((p) => p.fingerprint == masterId).firstOrNull;
    if (masterPeer == null) {
      return _errorData(StoreError.notPaired, 'master device not paired');
    }
    final reqId = frame.reqId ?? 'r-${_uuid.v4()}';
    final completer = Completer<Map<String, dynamic>?>();
    _pending[reqId] = completer;
    try {
      final wire = StoreFrame(op: frame.op, reqId: reqId, payload: frame.payload);
      final ok = await _manager.sendControl(masterPeer.id, wire.toJson());
      if (!ok) return _errorData(StoreError.masterOffline);
      return await completer.future.timeout(_callTimeout,
          onTimeout: () => _errorData(StoreError.masterOffline));
    } finally {
      _pending.remove(reqId);
    }
  }

  Map<String, dynamic> _errorData(String code, [String? message]) =>
      <String, dynamic>{
        '_error': code,
        if (message != null) 'message': message,
      };

  // ────────────────────────────── master 侧帧处理 ──

  void _onControl(PeerControlEvent event) {
    Map<String, dynamic>? decoded;
    try {
      decoded = event.data;
      final frame = StoreFrame.tryParse(decoded);
      if (frame == null) return;
      _handleInbound(event.peerId, frame).catchError((Object e, StackTrace st) {
        _log.error('inbound ${frame.op} handling failed',
            tag: _tag, error: e, stackTrace: st);
      });
    } on FormatException catch (e) {
      _log.warning('malformed store frame from ${event.peerId}: $e', tag: _tag);
    }
  }

  Future<void> _handleInbound(String peerId, StoreFrame frame) async {
    final peer = await _peerStorage.getPeerById(peerId);
    if (peer == null) {
      await _reply(peerId, frame, StoreError.notPaired);
      return;
    }
    // 响应帧：完成挂起的 Completer（本机作为客户端时的回程）
    if (frame.op == StoreOp.result || frame.op == StoreOp.error) {
      final reqId = frame.reqId;
      if (reqId != null && _pending.containsKey(reqId)) {
        _pending.remove(reqId)!.complete(frame.payload['data'] != null
            ? (frame.payload['data'] as Map).cast<String, dynamic>()
            : _errorData(
                frame.payload['code'] as String? ?? StoreError.internal,
                frame.payload['message'] as String?));
      }
      return;
    }
    // friend 级：一律拒绝并审计（spec §3）
    if (peer.trustLevel != TrustLevel.owner) {
      _log.warning(
          'reject ${frame.op} from friend-level peer ${peer.deviceName} ($peerId)',
          tag: _auditTag);
      await _reply(peerId, frame, StoreError.untrusted);
      return;
    }
    if (!frame.versionSupported) {
      await _reply(peerId, frame, StoreError.unsupportedVersion);
      return;
    }
    // 调用者身份 = 配对指纹（= 其 device_id），写路径收敛的锚点
    final data = await _dispatch(frame,
        callerDeviceId: peer.fingerprint,
        trustLevel: peer.trustLevel,
        loopback: false);
    await _replyData(peerId, frame, data);
  }

  Future<void> _reply(String peerId, StoreFrame frame, String code,
      [String? message]) async {
    await _manager.sendControl(
        peerId, storeError(frame.reqId, code, message).toJson());
  }

  Future<void> _replyData(
      String peerId, StoreFrame frame, Map<String, dynamic> data) async {
    if (data.containsKey('_error')) {
      await _reply(peerId, frame, data['_error'] as String,
          data['message'] as String?);
    } else {
      await _manager.sendControl(
          peerId, storeResult(frame.reqId, data).toJson());
    }
  }

  // ────────────────────────────── 统一执行器（loopback 与远端共用）──

  Future<Map<String, dynamic>> _dispatch(
    StoreFrame frame, {
    required String callerDeviceId,
    required String trustLevel,
    required bool loopback,
  }) async {
    // ACL（含路径/形态校验的粗筛；细粒度路径错误在执行期抛出）
    final verdict = checkStoreAcl(frame,
        callerDeviceId: callerDeviceId,
        trustLevel: trustLevel,
        loopback: loopback);
    if (verdict != StoreAcl.allow) {
      if (verdict == StoreAcl.denyAcl) {
        _log.warning(
            'acl denied: ${frame.op} caller=$callerDeviceId payload=${frame.payload}',
            tag: _auditTag);
      }
      return _errorData(storeAclErrorCode(verdict));
    }

    final store = await _localStore();
    try {
      switch (frame.op) {
        case StoreOp.list:
          final device = frame.device ?? callerDeviceId;
          final entries = await store.list(device, frame.space!,
              prefix: frame.payload['path'] as String?);
          return <String, dynamic>{
            'entries': [for (final e in entries) e.toJson()],
            'next_cursor': null,
          };

        case StoreOp.meta:
          return await store.meta(
              frame.device ?? callerDeviceId, frame.space!, frame.path!);

        case StoreOp.read:
          final (data, size, eof) = await store.read(
              frame.device ?? callerDeviceId,
              frame.space!,
              frame.path!,
              frame.payload['offset'] as int? ?? 0,
              frame.payload['length'] as int? ?? LocalStore.maxReadChunk);
          return <String, dynamic>{
            'data': base64Encode(data),
            'size': size,
            'eof': eof,
          };

        case StoreOp.writeBegin:
          final (uploadId, received) = await store.writeBegin(
            deviceId: callerDeviceId, // 写路径收敛：恒为调用者目录
            space: frame.space!,
            path: frame.path!,
            size: frame.payload['size'] as int? ?? -1,
            sha256: frame.payload['sha256'] as String? ?? '',
            uploadId: frame.payload['upload_id'] as String?,
          );
          return <String, dynamic>{
            'upload_id': uploadId,
            'received': received,
          };

        case StoreOp.writeChunk:
          final received = await store.writeChunk(
            callerDeviceId,
            frame.space!,
            frame.payload['upload_id'] as String,
            frame.payload['offset'] as int? ?? 0,
            base64Decode(frame.payload['data'] as String),
          );
          return <String, dynamic>{'received': received};

        case StoreOp.commit:
          final (committed, failed) = await store.commit(
            callerDeviceId,
            frame.space!,
            (frame.payload['upload_ids'] as List).cast<String>(),
          );
          return <String, dynamic>{
            'committed': committed,
            'failed': failed,
          };

        case StoreOp.delete:
          final recycled = await store.delete(
            frame.device ?? callerDeviceId,
            frame.space!,
            frame.path!,
          );
          return <String, dynamic>{'recycled': recycled};

        case StoreOp.recycleList:
          final entries = await store.recycleList();
          return <String, dynamic>{
            'entries': [for (final e in entries) e.toJson()],
          };

        case StoreOp.recycleRestore:
          final restored = await store
              .recycleRestore(frame.payload['recycle_path'] as String);
          return <String, dynamic>{'restored': restored};

        case StoreOp.recycleEmpty:
          final purged = await store.recycleEmpty();
          return <String, dynamic>{'purged_bytes': purged};

        case StoreOp.stats:
          return await store.stats();

        default:
          return _errorData(StoreError.badOp, 'unsupported op ${frame.op}');
      }
    } on StoreException catch (e) {
      return _errorData(e.code, e.message);
    } on BadPathException catch (e) {
      return _errorData(StoreError.badPath, e.reason);
    } on FormatException catch (e) {
      return _errorData(StoreError.badOp, '$e');
    } catch (e) {
      _log.error('dispatch ${frame.op} failed', tag: _tag, error: e);
      return _errorData(StoreError.internal, '$e');
    }
  }
}

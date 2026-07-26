import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_cursor_store.dart';
import 'device_identity.dart';
import 'import_auth_service.dart';
import 'local_store.dart';
import 'master_migration_service.dart';
import 'store_protocol.dart';
import 'sync_engine.dart';

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
  ImportAuthService? _importAuth;
  DeviceCursorStore? _cursorStore;
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
    final purged = await store.gcRecycle();
    if (purged > 0) {
      _log.info('gc recycle: purged $purged bytes', tag: _tag);
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

  Future<ImportAuthService> _importAuthService() async {
    final existing = _importAuth;
    if (existing != null) return existing;
    final store = await _localStore();
    return _importAuth = ImportAuthService(storeRoot: store.root);
  }

  Future<DeviceCursorStore> _deviceCursorStore() async {
    final existing = _cursorStore;
    if (existing != null) return existing;
    final store = await _localStore();
    return _cursorStore = DeviceCursorStore(storeRoot: store.root);
  }

  /// 本机 LocalStore（同步引擎读取本机正式区用）。
  Future<LocalStore> localStore() => _localStore();

  /// store 根目录（同步引擎/授权服务共用）。
  Future<Directory> storeRoot() async => (await _localStore()).root;

  /// 远端 master 是否在线（同步引擎用）。
  Future<bool> masterOnline() async {
    final masterId = await masterDeviceId();
    final self = await DeviceIdentity.deviceId();
    if (masterId == self) return true;
    final peers = await _peerStorage.loadAllPeers();
    final masterPeer =
        peers.where((p) => p.fingerprint == masterId).firstOrNull;
    if (masterPeer == null) return false;
    return _manager.connectedPeerIds.contains(masterPeer.id);
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
    return _callPeerId(masterPeer.id, frame);
  }

  /// 向指定设备（device_id）直发请求（换机导入路径 A：旧设备在场，
  /// 由旧设备直接服务，§5.4）。
  Future<Map<String, dynamic>?> callPeer(
      String deviceId, StoreFrame frame) async {
    final self = await DeviceIdentity.deviceId();
    if (deviceId == self) {
      return _dispatch(frame,
          callerDeviceId: self,
          trustLevel: TrustLevel.owner,
          loopback: true);
    }
    final peers = await _peerStorage.loadAllPeers();
    final peer = peers.where((p) => p.fingerprint == deviceId).firstOrNull;
    if (peer == null) {
      return _errorData(StoreError.notPaired, 'device not paired');
    }
    return _callPeerId(peer.id, frame);
  }

  Future<Map<String, dynamic>?> _callPeerId(
      String peerId, StoreFrame frame) async {
    final reqId = frame.reqId ?? 'r-${_uuid.v4()}';
    final completer = Completer<Map<String, dynamic>?>();
    _pending[reqId] = completer;
    try {
      final wire = StoreFrame(
          op: frame.op, reqId: reqId, v: frame.v, payload: frame.payload);
      final ok = await _manager.sendControl(peerId, wire.toJson());
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
    // 换机导入授权推送（请求方侧落库，无 req_id 的通知帧）
    if (frame.op == StoreOp.importGrant && frame.reqId == null) {
      await _receivePushedGrant(peer.fingerprint, frame);
      return;
    }
    // master 指针广播（M6，无 req_id）
    if (frame.op == StoreOp.masterPointer && frame.reqId == null) {
      await MasterMigrationService.instance.applyPointer(
        masterId: frame.payload['master'] as String? ?? '',
        epoch: frame.payload['epoch'] as int? ?? 0,
        fromDeviceId: peer.fingerprint,
      );
      return;
    }
    // 调用者身份 = 配对指纹（= 其 device_id），写路径收敛的锚点
    final data = await _dispatch(frame,
        callerDeviceId: peer.fingerprint,
        trustLevel: peer.trustLevel,
        loopback: false);
    await _replyData(peerId, frame, data);
  }

  /// 请求方收到服务侧签发的授权推送：持久化到 received。
  Future<void> _receivePushedGrant(
      String fromDevice, StoreFrame frame) async {
    try {
      final self = await DeviceIdentity.deviceId();
      final grant = ImportGrant(
        grantId: frame.payload['grant_id'] as String,
        oldDevice: fromDevice,
        newDevice: self,
        spaces: (frame.payload['spaces'] as List).cast<String>(),
        issuedAtMs: frame.payload['issued_at'] as int? ?? 0,
        expiresAtMs: frame.payload['expires_at'] as int? ?? 0,
      );
      if (grant.oldDevice.isEmpty || grant.newDevice.isEmpty) return;
      final auth = await _importAuthService();
      await auth.saveReceivedGrant(grant);
      _log.info(
          'received import grant ${grant.grantId} from $fromDevice',
          tag: _tag);
    } catch (e) {
      _log.warning('invalid pushed import grant: $e', tag: _tag);
    }
  }

  /// 签发后把授权推送给请求方（新设备）。
  Future<void> _pushGrantToRequester(ImportGrant grant) async {
    try {
      final peers = await _peerStorage.loadAllPeers();
      final requester =
          peers.where((p) => p.fingerprint == grant.newDevice).firstOrNull;
      if (requester == null) {
        _log.warning(
            'grant requester ${grant.newDevice} not paired; grant pending',
            tag: _tag);
        return;
      }
      await _manager.sendControl(
          requester.id,
          StoreFrame(op: StoreOp.importGrant, payload: <String, dynamic>{
            'grant_id': grant.grantId,
            'old_device': grant.oldDevice,
            'spaces': grant.spaces,
            'issued_at': grant.issuedAtMs,
            'expires_at': grant.expiresAtMs,
          }).toJson());
    } catch (e) {
      _log.warning('push grant failed: $e', tag: _tag);
    }
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

  /// 测试钩子：以指定调用者身份/信任等级走完整 dispatch（含 grant 校验）。
  @visibleForTesting
  Future<Map<String, dynamic>> dispatchForTest(
    StoreFrame frame, {
    required String callerDeviceId,
    required String trustLevel,
    bool loopback = false,
  }) =>
      _dispatch(frame,
          callerDeviceId: callerDeviceId,
          trustLevel: trustLevel,
          loopback: loopback);

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
      // 私有分区跨端读取：校验导入授权实体（spec §5.4）
      if ((frame.op == StoreOp.list ||
              frame.op == StoreOp.meta ||
              frame.op == StoreOp.read) &&
          frame.device != null &&
          frame.device != callerDeviceId &&
          !StoreSpace.sharedReadable.contains(frame.space)) {
        final grantId = frame.payload['grant'] as String?;
        final auth = await _importAuthService();
        final ok = grantId != null &&
            await auth.validate(grantId,
                oldDevice: frame.device!,
                newDevice: callerDeviceId,
                space: frame.space!);
        if (!ok) {
          _log.warning(
              'invalid import grant from $callerDeviceId for ${frame.device}/${frame.space}',
              tag: _auditTag);
          return _errorData(StoreError.aclDenied, 'invalid import grant');
        }
      }

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
          // v3：携带 upto_seq 时推进该设备游标（spec §6.2）
          int? appliedSeq;
          final uptoSeq = frame.payload['upto_seq'] as int?;
          if (uptoSeq != null && failed.isEmpty) {
            appliedSeq = await (await _deviceCursorStore())
                .advance(callerDeviceId, uptoSeq);
          }
          return <String, dynamic>{
            'committed': [for (final f in committed) f.path],
            'failed': failed,
            if (appliedSeq != null) 'applied_seq': appliedSeq,
          };

        case StoreOp.delete:
          final recycled = await store.delete(
            frame.device ?? callerDeviceId,
            frame.space!,
            frame.path!,
          );
          int? appliedSeq;
          final uptoSeq = frame.payload['upto_seq'] as int?;
          if (uptoSeq != null) {
            appliedSeq = await (await _deviceCursorStore())
                .advance(callerDeviceId, uptoSeq);
          }
          return <String, dynamic>{
            'recycled': recycled,
            if (appliedSeq != null) 'applied_seq': appliedSeq,
          };

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
          final base = await store.stats();
          // v3：本机未同步占用与游标水位（spec §6.1，管理页展示）
          final journal = SyncEngine.instance.journal;
          if (journal != null) {
            base['unsynced_count'] = await journal.pendingCount();
            base['unsynced_bytes'] = await journal.pendingBytes();
            final cursors = await journal.cursors();
            base['change_seq'] = cursors.changeSeq;
            base['ack_seq'] = cursors.ackSeq;
          }
          return base;

        // ── 变更游标对账（v3，spec §6.2）──
        case StoreOp.syncHello:
          final cursors = await _deviceCursorStore();
          return <String, dynamic>{
            'applied_seq': await cursors.appliedSeq(callerDeviceId),
          };

        // ── master 迁移 / 指针（v4，方案 §6.5）──
        case StoreOp.syncCursors:
          final cursors = await _deviceCursorStore();
          return <String, dynamic>{'cursors': await cursors.all()};

        case StoreOp.masterPointerQuery:
          return <String, dynamic>{
            'master': await masterDeviceId(),
            'epoch': await MasterMigrationService.instance.currentEpoch(),
          };

        case StoreOp.masterMigrate:
          // 对端请求本机升主
          final result =
              await MasterMigrationService.instance.promoteSelf();
          return <String, dynamic>{
            'master': result.newMasterId,
            'epoch': result.epoch,
            'old_master_reachable': result.oldMasterReachable,
            'cursors': result.seededCursors,
            'broadcast_peers': result.broadcastPeers,
          };

        // ── 换机导入授权（v2，§5.4）──
        case StoreOp.importRequest:
          final auth = await _importAuthService();
          final req = await auth.createRequest(
            oldDevice: frame.payload['old_device'] as String,
            newDevice: callerDeviceId,
          );
          _log.info(
              'import request from $callerDeviceId for ${req.oldDevice}',
              tag: _auditTag);
          return <String, dynamic>{
            'request_id': req.requestId,
            'status': req.status,
          };

        case StoreOp.importPending:
          final auth = await _importAuthService();
          final pending = await auth.pendingRequests();
          return <String, dynamic>{
            'requests': [for (final r in pending) r.toJson()],
          };

        case StoreOp.importGrant:
          // 仅 loopback（用户在场确认，ACL 已强制）
          final auth = await _importAuthService();
          final grant = await auth
              .grant(frame.payload['request_id'] as String);
          _log.info(
              'import granted ${grant.grantId} to ${grant.newDevice}',
              tag: _auditTag);
          // 推送授权给请求方（新设备）
          unawaited(_pushGrantToRequester(grant));
          return <String, dynamic>{'grant': grant.toJson()};

        case StoreOp.importReject:
          final auth = await _importAuthService();
          await auth.reject(frame.payload['request_id'] as String);
          return <String, dynamic>{'rejected': true};

        case StoreOp.importGrants:
          final auth = await _importAuthService();
          final role = frame.payload['role'] as String? ?? 'received';
          final grants = role == 'issued'
              ? await auth.issuedGrants()
              : await auth.receivedGrants();
          return <String, dynamic>{
            'grants': [for (final g in grants) g.toJson()],
          };

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

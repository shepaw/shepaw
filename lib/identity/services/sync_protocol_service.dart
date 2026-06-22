import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/owned_device_record.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'blob_sync_service.dart';
import 'device_rpc_service.dart';
import 'device_trust_service.dart';
import 'sync_engine.dart';

/// sync_query 等待响应超时。
class SyncQueryTimeoutException implements Exception {
  final String requestId;
  const SyncQueryTimeoutException(this.requestId);

  @override
  String toString() => 'Sync query timed out: $requestId';
}

/// P2P 账号同步协议（Noise 加密通道内的 control 消息）。
class SyncProtocolService {
  SyncProtocolService._();
  static final SyncProtocolService instance = SyncProtocolService._();

  static const _tag = 'SyncProtocol';
  final _log = LoggerService();
  final _db = LocalDatabaseService();

  StreamSubscription<PeerControlEvent>? _sub;
  bool _running = false;

  final _queryWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _commitWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _blobWaiters = <String, Completer<Map<String, dynamic>?>>{};
  final _blobPushAckWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _deviceRpcWaiters = <String, Completer<Map<String, dynamic>?>>{};

  void start() {
    if (_running) return;
    _running = true;
    _sub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _log.info('SyncProtocolService started', tag: _tag);
    unawaited(_announceRoleToOwnedPeers());
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
  }

  Future<Map<String, dynamic>> waitQueryResponse(String requestId, {required Duration timeout}) {
    final c = Completer<Map<String, dynamic>>();
    _queryWaiters[requestId] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _queryWaiters.remove(requestId);
      throw SyncQueryTimeoutException(requestId);
    });
  }

  Future<Map<String, dynamic>?> waitCommitResponse(String requestId, {required Duration timeout}) {
    final c = Completer<Map<String, dynamic>>();
    _commitWaiters[requestId] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _commitWaiters.remove(requestId);
      return <String, dynamic>{'ok': false, 'error': 'timeout'};
    });
  }

  Future<Map<String, dynamic>?> waitBlobResponse(String requestId, {required Duration timeout}) {
    final c = Completer<Map<String, dynamic>?>();
    _blobWaiters[requestId] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _blobWaiters.remove(requestId);
      return null;
    });
  }

  Future<Map<String, dynamic>?> waitBlobPushAck(String requestId, {required Duration timeout}) {
    final c = Completer<Map<String, dynamic>>();
    _blobPushAckWaiters[requestId] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _blobPushAckWaiters.remove(requestId);
      return <String, dynamic>{'ok': false};
    });
  }

  Future<Map<String, dynamic>?> waitDeviceRpcResponse(String requestId, {required Duration timeout}) {
    final c = Completer<Map<String, dynamic>?>();
    _deviceRpcWaiters[requestId] = c;
    return c.future.timeout(timeout, onTimeout: () {
      _deviceRpcWaiters.remove(requestId);
      return null;
    });
  }

  Future<void> _announceRoleToOwnedPeers() async {
    try {
      await AccountIdentityService.instance.ensureInitialized();
      final local = await AccountIdentityService.instance.localDevice();
      if (local == null) return;

      final owned = await AccountIdentityService.instance.ownedDevices();
      for (final peer in owned) {
        if (peer.isLocal) continue;
        await _sendRoleAnnounce(peer.deviceId, local);
      }
    } catch (e) {
      _log.warning('Role announce failed: $e', tag: _tag);
    }
  }

  Future<void> _sendRoleAnnounce(String peerDeviceId, OwnedDeviceRecord local) async {
    final paired = await _findPairedPeerId(peerDeviceId);
    if (paired == null) return;

    await PeerConnectionManager.instance.sendControl(paired, {
      'type': 'sync_role_announce',
      'device_id': local.deviceId,
      'device_name': local.deviceName,
      'role': local.role.wireValue,
      'user_id': local.userId,
      'pet_id': local.petId,
      'transport_fingerprint': local.fingerprint,
    });
  }

  Future<String?> _findPairedPeerId(String deviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == deviceId) return p.id;
    }
    return null;
  }

  void _onControl(PeerControlEvent event) {
    switch (event.type) {
      case 'sync_role_announce':
        unawaited(_handleRoleAnnounce(event));
        break;
      case 'sync_hello':
        unawaited(_handleHello(event.peerId, event.data));
        break;
      case 'sync_query':
        unawaited(_handleQuery(event.peerId, event.data));
        break;
      case 'sync_query_resp':
        _completeQueryWaiter(event.data);
        break;
      case 'sync_commit':
        unawaited(_handleCommit(event.peerId, event.data));
        break;
      case 'sync_commit_resp':
        _completeCommitWaiter(event.data);
        break;
      case 'sync_push':
        unawaited(_handlePush(event.data));
        break;
      case 'sync_trust_accept':
        unawaited(_handleTrustAccept(event.peerId, event.data));
        break;
      case 'sync_blob_req':
        unawaited(_handleBlobReq(event.peerId, event.data));
        break;
      case 'sync_blob_resp':
        _completeBlobWaiter(event.data);
        break;
      case 'sync_blob_push':
        unawaited(_handleBlobPush(event.peerId, event.data));
        break;
      case 'sync_blob_push_ack':
        _completeBlobPushAck(event.data);
        break;
      case 'device_rpc':
        unawaited(_handleDeviceRpc(event.peerId, event.data));
        break;
      case 'device_rpc_resp':
        _completeDeviceRpcWaiter(event.data);
        break;
      case 'sync_ack':
        break;
    }
  }

  void _completeQueryWaiter(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _queryWaiters.remove(id)?.complete(data);
  }

  void _completeCommitWaiter(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _commitWaiters.remove(id)?.complete(data);
  }

  void _completeBlobWaiter(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _blobWaiters.remove(id)?.complete(data);
  }

  void _completeBlobPushAck(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _blobPushAckWaiters.remove(id)?.complete(data);
  }

  void _completeDeviceRpcWaiter(Map<String, dynamic> data) {
    final id = data['request_id'] as String?;
    if (id == null) return;
    _deviceRpcWaiters.remove(id)?.complete(data);
  }

  Future<void> _handleRoleAnnounce(PeerControlEvent event) async {
    final data = event.data;
    final remoteDeviceId = data['device_id'] as String?;
    if (remoteDeviceId == null) return;

    await AccountIdentityService.instance.ensureInitialized();
    final user = await AccountIdentityService.instance.userIdentity();
    if (data['user_id'] != user.fingerprintHex) {
      _log.warning('Ignoring sync_role_announce: user_id mismatch', tag: _tag);
      return;
    }

    final existing = await _db.getOwnedDeviceByDeviceId(remoteDeviceId);
    final now = DateTime.now().millisecondsSinceEpoch;

    if (existing != null) {
      await _db.upsertOwnedDevice(existing.copyWith(
        deviceName: data['device_name'] as String? ?? existing.deviceName,
        role: DeviceRole.fromWire(data['role'] as String?),
        lastSeenAt: now,
      ));
      return;
    }

    // 无 transport 公钥时不自动登记未知设备，等待 join/trust 流程。
    _log.info('Ignoring sync_role_announce for unknown device $remoteDeviceId', tag: _tag);
  }

  Future<void> _handleTrustAccept(String peerId, Map<String, dynamic> data) async {
    await AccountIdentityService.instance.ensureInitialized();
    final user = await AccountIdentityService.instance.userIdentity();
    if (data['user_id'] != user.fingerprintHex) return;

    final pubB64 = data['transport_public_key'] as String?;
    if (pubB64 == null) return;
    final pub = base64.decode(pubB64);

    await DeviceTrustService.instance.registerTrustedRemoteDevice(
      deviceId: data['device_id'] as String,
      deviceName: data['device_name'] as String? ?? 'Device',
      transportPublicKey: Uint8List.fromList(pub),
      fingerprint: data['transport_fingerprint'] as String? ?? '',
      role: DeviceRole.fromWire(data['role'] as String?),
    );
    _log.info('Registered trusted device via sync_trust_accept', tag: _tag);
  }

  Future<void> _handleHello(String peerId, Map<String, dynamic> data) async {
    final local = await AccountIdentityService.instance.localDevice();
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'sync_hello_resp',
      'device_id': local?.deviceId,
      'role': local?.role.wireValue,
      'user_id': local?.userId,
      'pet_id': local?.petId,
    });
  }

  Future<void> _handleQuery(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary && role != DeviceRole.backup) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_query_resp',
        'request_id': requestId,
        'error': 'not_storage_device',
        'events': <Map<String, dynamic>>[],
      });
      return;
    }

    final sinceMs = data['since_ms'] as int? ?? 0;
    final limit = data['limit'] as int? ?? 50;
    final channelId = data['channel_id'] as String?;
    final domain = data['domain'] as String?;

    final List<SyncEvent> events;
    if (domain == 'message') {
      events = await SyncEngine.instance.queryMessageEvents(
        sinceMs: sinceMs,
        channelId: channelId,
        limit: limit,
      );
    } else if (domain == 'channel') {
      events = await SyncEngine.instance.queryChannelEvents(
        sinceMs: sinceMs,
        limit: limit,
      );
    } else if (domain == 'channel_member') {
      events = await SyncEngine.instance.queryChannelMemberEvents(
        sinceMs: sinceMs,
        limit: limit,
      );
    } else {
      events = await SyncEngine.instance.queryEvents(
        sinceMs: sinceMs,
        channelId: channelId,
        limit: limit,
      );
    }

    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'sync_query_resp',
      'request_id': requestId,
      'events': events.map((e) => e.toJson()).toList(),
    });
  }

  Future<void> _handleCommit(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': false,
        'error': 'primary_required',
      });
      return;
    }

    try {
      final eventMap = data['event'] as Map<String, dynamic>?;
      if (eventMap == null) throw FormatException('missing event');
      final event = SyncEvent.fromJson(eventMap);
      final ok = await SyncEngine.instance.commitEvent(event);
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': ok,
      });
      if (ok) {
        unawaited(_pushToBackups([event]));
      }
    } catch (e) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': false,
        'error': e.toString(),
      });
    }
  }

  Future<void> _handlePush(Map<String, dynamic> data) async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.backup && role != DeviceRole.app) return;

    final eventsRaw = (data['events'] as List?) ?? const [];
    final events = eventsRaw
        .whereType<Map>()
        .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    await SyncEngine.instance.applyEvents(events);
  }

  /// 向已关联 App/Backup 设备推送事件（Primary commit 或本地写入后 fan-out）。
  Future<void> pushEventsToPeers(List<SyncEvent> events) async {
    await _pushToBackups(events);
  }

  Future<void> _pushToBackups(List<SyncEvent> events) async {
    if (events.isEmpty) return;
    final owned = await AccountIdentityService.instance.ownedDevices();
    final local = await AccountIdentityService.instance.localDevice();
    for (final d in owned) {
      if (d.isLocal) continue;
      if (d.deviceId == local?.deviceId) continue;
      if (d.role != DeviceRole.backup && d.role != DeviceRole.app) continue;
      final peerId = await _findPairedPeerId(d.deviceId);
      if (peerId == null) continue;
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push',
        'events': events.map((e) => e.toJson()).toList(),
      });
    }
  }

  Future<void> _handleBlobReq(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final blobKey = data['blob_key'] as String?;
    if (blobKey == null) return;

    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary && role != DeviceRole.backup) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_resp',
        'request_id': requestId,
        'error': 'not_storage_device',
      });
      return;
    }

    final offset = data['offset'] as int? ?? 0;
    final limit = data['limit'] as int? ?? BlobSyncService.chunkSize;
    final chunk = await BlobSyncService.instance.readBlobChunk(blobKey, offset, limit);
    if (chunk == null) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_resp',
        'request_id': requestId,
        'error': 'blob_not_found',
      });
      return;
    }

    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': 'sync_blob_resp',
      'request_id': requestId,
      'blob_key': blobKey,
      ...chunk,
    });
  }

  Future<void> _handleBlobPush(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.primary) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_push_ack',
        'request_id': requestId,
        'ok': false,
        'error': 'primary_required',
      });
      return;
    }

    try {
      final blobKey = data['blob_key'] as String;
      final offset = data['offset'] as int? ?? 0;
      final totalSize = data['total_size'] as int? ?? 0;
      final sha = data['sha256'] as String? ?? '';
      final done = data['done'] == true;
      final chunk = base64.decode(data['data_b64'] as String? ?? '');

      final ok = await BlobSyncService.instance.receiveBlobPush(
        blobKey: blobKey,
        offset: offset,
        totalSize: totalSize,
        sha256Expected: sha,
        chunk: Uint8List.fromList(chunk),
        done: done,
      );

      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_push_ack',
        'request_id': requestId,
        'ok': ok,
      });
    } catch (e) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_push_ack',
        'request_id': requestId,
        'ok': false,
        'error': e.toString(),
      });
    }
  }

  Future<void> _handleDeviceRpc(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final method = data['method'] as String? ?? '';
    final params = Map<String, dynamic>.from(data['params'] as Map? ?? {});

    try {
      final result = await DeviceRpcService.instance.handleInbound(method: method, params: params);
      final error = result['error'];
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'device_rpc_resp',
        'request_id': requestId,
        if (error != null) 'error': error else 'result': result,
      });
    } catch (e) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'device_rpc_resp',
        'request_id': requestId,
        'error': e.toString(),
      });
    }
  }
}

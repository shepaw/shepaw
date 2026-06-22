import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../peer/models/paired_peer.dart';
import '../../peer/services/peer_connection.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'blob_sync_service.dart';
import 'device_rpc_service.dart';
import 'device_trust_service.dart';
import 'sync_engine.dart';
import 'sync_role_service.dart';

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
  final _uuid = const Uuid();

  StreamSubscription<PeerControlEvent>? _sub;
  StreamSubscription<PeerConnectionEvent>? _connSub;
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
    _connSub = PeerConnectionManager.instance.events.listen(_onPeerConnection);
    _log.info('SyncProtocolService started', tag: _tag);
    unawaited(SyncRoleService.announceLocalRole());
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    _connSub?.cancel();
    _connSub = null;
  }

  void _onPeerConnection(PeerConnectionEvent event) {
    if (event.type != PeerConnectionEventType.connected) return;
    unawaited(_onStoragePeerConnected(event.peerId));
  }

  Future<void> _onStoragePeerConnected(String peerId) async {
    try {
      if (await AccountIdentityService.instance.isCanonicalPrimary()) {
        final peer = await PeerStorageService().getPeerById(peerId);
        if (peer?.deviceId != null) {
          await _retryPushOutboxForDevice(peer!.deviceId!);
        }
        return;
      }
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.backup) return;
      final primary = await AccountIdentityService.instance.primaryDevice();
      final peer = await PeerStorageService().getPeerById(peerId);
      if (primary != null && peer?.deviceId == primary.deviceId) {
        await _drainBackupRelayQueue(peerId);
      }
    } catch (e) {
      _log.warning('Storage peer connect hook failed: $e', tag: _tag);
    }
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

  Future<String?> _findPairedPeerId(String deviceId) async {
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == deviceId) return p.id;
    }
    return null;
  }

  Future<bool> _isOwnedAccountPeer(String peerId) async {
    await AccountIdentityService.instance.ensureInitialized();
    final peer = await PeerStorageService().getPeerById(peerId);
    final deviceId = peer?.deviceId;
    if (deviceId == null || deviceId.isEmpty) return false;
    final owned = await _db.getOwnedDeviceByDeviceId(deviceId);
    return owned != null;
  }

  Future<void> _rejectUnauthorizedPeer(
    String peerId, {
    required String respType,
    required String requestId,
    String error = 'unauthorized_peer',
  }) async {
    _log.warning('Rejecting sync from unauthorized peer $peerId', tag: _tag);
    await PeerConnectionManager.instance.sendControl(peerId, {
      'type': respType,
      'request_id': requestId,
      'error': error,
      if (respType == 'sync_query_resp') 'events': <Map<String, dynamic>>[],
    });
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
        unawaited(_handlePush(event.peerId, event.data));
        break;
      case 'sync_push_ack':
        unawaited(_handlePushAck(event.data));
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
    if (existing == null) {
      _log.info('Ignoring sync_role_announce for unknown device $remoteDeviceId', tag: _tag);
      return;
    }

    if (data.containsKey('elected_primary_device_id')) {
      final elected = data['elected_primary_device_id'] as String? ?? '';
      await AccountIdentityService.instance.applyRemoteUserElectedPrimary(
        elected.isEmpty ? null : elected,
      );
    }

    await AccountIdentityService.instance.reconcileRemoteDeviceRole(
      remoteDeviceId: remoteDeviceId,
      announcedRole: DeviceRole.fromWire(data['role'] as String?),
      deviceName: data['device_name'] as String?,
    );
  }

  Future<void> _handleTrustAccept(String peerId, Map<String, dynamic> data) async {
    if (!await _isOwnedAccountPeer(peerId)) {
      _log.warning('Ignoring sync_trust_accept from unauthorized peer $peerId', tag: _tag);
      return;
    }

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
    if (!await _isOwnedAccountPeer(peerId)) {
      await _rejectUnauthorizedPeer(peerId, respType: 'sync_query_resp', requestId: requestId);
      return;
    }

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
    final sinceEventId = data['since_event_id'] as String? ?? '';
    final limit = data['limit'] as int? ?? 50;
    final channelId = data['channel_id'] as String?;
    final domain = data['domain'] as String?;

    final List<SyncEvent> events;
    if (domain == 'message') {
      events = await SyncEngine.instance.queryMessageEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        channelId: channelId,
        limit: limit,
      );
    } else if (domain == 'channel') {
      events = await SyncEngine.instance.queryChannelEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        limit: limit,
      );
    } else if (domain == 'channel_member') {
      events = await SyncEngine.instance.queryChannelMemberEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        limit: limit,
      );
    } else if (domain == 'agent') {
      events = await SyncEngine.instance.queryAgentEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        limit: limit,
      );
    } else if (domain == 'she_memory') {
      events = await SyncEngine.instance.querySheMemoryEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        limit: limit,
      );
    } else if (domain == 'cognition') {
      events = await SyncEngine.instance.queryCognitionEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
        limit: limit,
      );
    } else if (domain == 'agent_memory') {
      events = await SyncEngine.instance.queryAgentMemoryEvents(
        sinceMs: sinceMs,
        sinceEventId: sinceEventId,
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
    if (!await _isOwnedAccountPeer(peerId)) {
      await _rejectUnauthorizedPeer(peerId, respType: 'sync_commit_resp', requestId: requestId);
      return;
    }

    try {
      final eventMap = data['event'] as Map<String, dynamic>?;
      if (eventMap == null) throw FormatException('missing event');
      final event = SyncEvent.fromJson(eventMap);

      if (await AccountIdentityService.instance.isCanonicalPrimary()) {
        final result = await SyncEngine.instance.commitEvent(event);
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_commit_resp',
          'request_id': requestId,
          'ok': result.ok,
          'applied': result.applied,
          'stale': result.stale,
        });
        if (result.applied) {
          unawaited(_pushToBackups([event]));
        }
        unawaited(SyncEngine.instance.pruneOldTombstones());
        return;
      }

      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role == DeviceRole.backup) {
        final relayResp = await _forwardCommitToPrimary(data);
        if (relayResp != null) {
          if (relayResp['applied'] == true) {
            await SyncEngine.instance.commitEventAsStorageRelay(event);
          }
          await PeerConnectionManager.instance.sendControl(peerId, {
            'type': 'sync_commit_resp',
            'request_id': requestId,
            'ok': relayResp['ok'],
            'applied': relayResp['applied'],
            'stale': relayResp['stale'],
            if (relayResp['error'] != null) 'error': relayResp['error'],
          });
          return;
        }

        final result = await SyncEngine.instance.commitEventAsStorageRelay(event);
        await _db.enqueueBackupRelayEvent(
          id: event.eventId,
          payloadJson: jsonEncode(eventMap),
        );
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_commit_resp',
          'request_id': requestId,
          'ok': result.ok,
          'applied': result.applied,
          'stale': result.stale,
          'relayed_via': 'backup',
        });
        return;
      }

      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': false,
        'error': 'primary_required',
      });
    } catch (e) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': false,
        'error': e.toString(),
      });
    }
  }

  Future<Map<String, dynamic>?> _forwardCommitToPrimary(Map<String, dynamic> data) async {
    final primary = await AccountIdentityService.instance.primaryDevice();
    if (primary == null) return null;
    final primaryPeerId = await _findPairedPeerId(primary.deviceId);
    if (primaryPeerId == null) return null;
    if (PeerConnectionManager.instance.getPeerState(primaryPeerId) !=
        PeerConnectionState.connected) {
      return null;
    }

    final requestId = data['request_id'] as String? ?? _uuid.v4();
    await PeerConnectionManager.instance.sendControl(primaryPeerId, {
      'type': 'sync_commit',
      'request_id': requestId,
      'event': data['event'],
    });
    final resp = await waitCommitResponse(
      requestId,
      timeout: const Duration(seconds: 15),
    );
    if (resp == null) return null;
    return Map<String, dynamic>.from(resp);
  }

  Future<void> _drainBackupRelayQueue(String primaryPeerId) async {
    final pending = await _db.listPendingBackupRelay(limit: 50);
    for (final row in pending) {
      final rowId = row['id'] as String;
      final payloadRaw = row['payload'] as String? ?? '';
      Map<String, dynamic> eventMap;
      try {
        eventMap = jsonDecode(payloadRaw) as Map<String, dynamic>;
      } catch (_) {
        await _db.markBackupRelayAcked(rowId);
        continue;
      }

      final requestId = _uuid.v4();
      await PeerConnectionManager.instance.sendControl(primaryPeerId, {
        'type': 'sync_commit',
        'request_id': requestId,
        'event': eventMap,
      });
      final resp = await waitCommitResponse(
        requestId,
        timeout: const Duration(seconds: 15),
      );
      final ok = resp?['ok'] == true;
      if (ok) {
        await _db.markBackupRelayAcked(rowId);
      }
    }
  }

  Future<void> _handlePush(String peerId, Map<String, dynamic> data) async {
    if (!await _isOwnedAccountPeer(peerId)) {
      _log.warning('Ignoring sync_push from unauthorized peer $peerId', tag: _tag);
      return;
    }

    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.backup && role != DeviceRole.app) return;

    final eventsRaw = (data['events'] as List?) ?? const [];
    final events = eventsRaw
        .whereType<Map>()
        .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    await SyncEngine.instance.applyEvents(events);

    final pushId = data['push_id'] as String?;
    if (pushId != null && pushId.isNotEmpty) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push_ack',
        'push_id': pushId,
      });
    }
  }

  Future<void> _handlePushAck(Map<String, dynamic> data) async {
    final pushId = data['push_id'] as String?;
    if (pushId == null || pushId.isEmpty) return;
    await _db.markSyncPushAcked(pushId);
  }

  Future<void> pushEventsToPeers(List<SyncEvent> events) async {
    if (!await AccountIdentityService.instance.isCanonicalPrimary()) return;
    await _pushToBackups(events);
  }

  Future<void> _pushToBackups(List<SyncEvent> events) async {
    if (events.isEmpty) return;
    final owned = await AccountIdentityService.instance.ownedDevices();
    final local = await AccountIdentityService.instance.localDevice();
    final eventsJson = events.map((e) => e.toJson()).toList();
    for (final d in owned) {
      if (d.isLocal) continue;
      if (d.deviceId == local?.deviceId) continue;
      if (d.role != DeviceRole.backup && d.role != DeviceRole.app) continue;
      final peerId = await _findPairedPeerId(d.deviceId);
      if (peerId == null) continue;

      final pushId = _uuid.v4();
      await _db.enqueueSyncPushOutbox(
        pushId: pushId,
        targetDeviceId: d.deviceId,
        payloadJson: jsonEncode(eventsJson),
      );
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push',
        'push_id': pushId,
        'events': eventsJson,
      });
    }
  }

  Future<void> _retryPushOutboxForDevice(String targetDeviceId) async {
    final pending = await _db.listPendingSyncPushForDevice(targetDeviceId);
    for (final row in pending) {
      final pushId = row['id'] as String;
      final payloadRaw = row['payload'] as String? ?? '[]';
      final peerId = await _findPairedPeerId(targetDeviceId);
      if (peerId == null) continue;
      if (PeerConnectionManager.instance.getPeerState(peerId) !=
          PeerConnectionState.connected) {
        continue;
      }
      List<dynamic> eventsJson;
      try {
        eventsJson = jsonDecode(payloadRaw) as List<dynamic>;
      } catch (_) {
        await _db.markSyncPushAcked(pushId);
        continue;
      }
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push',
        'push_id': pushId,
        'events': eventsJson,
      });
    }
  }

  Future<void> _handleBlobReq(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    if (!await _isOwnedAccountPeer(peerId)) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_resp',
        'request_id': requestId,
        'error': 'unauthorized_peer',
      });
      return;
    }

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
    if (!await _isOwnedAccountPeer(peerId)) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_push_ack',
        'request_id': requestId,
        'ok': false,
        'error': 'unauthorized_peer',
      });
      return;
    }

    if (!await AccountIdentityService.instance.isCanonicalPrimary()) {
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
    if (!await _isOwnedAccountPeer(peerId)) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'device_rpc_resp',
        'request_id': requestId,
        'error': 'unauthorized_peer',
      });
      return;
    }

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

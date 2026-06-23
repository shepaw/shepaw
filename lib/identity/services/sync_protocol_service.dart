import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../peer/models/paired_peer.dart';
import '../../peer/services/peer_connection.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_commit_result.dart';
import '../models/sync_push_apply_result.dart';
import '../models/sync_event.dart';
import '../utils/blob_path_utils.dart';
import 'account_identity_service.dart';
import 'blob_sync_service.dart';
import '../utils/device_rpc_policy.dart';
import 'device_rpc_service.dart';
import 'device_trust_service.dart';
import 'sync_engine.dart';
import 'sync_role_service.dart';
import '../utils/sync_push_backoff.dart';

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
  Timer? _pushRetryTimer;
  Timer? _relayRetryTimer;
  bool _running = false;

  static const _pushRetryInterval = Duration(seconds: 30);

  final _queryWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _commitWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _blobWaiters = <String, Completer<Map<String, dynamic>?>>{};
  final _blobPushAckWaiters = <String, Completer<Map<String, dynamic>>>{};
  final _deviceRpcWaiters = <String, Completer<Map<String, dynamic>?>>{};
  final _backupRelayStaleController = StreamController<void>.broadcast();

  /// Backup relay 收到 Primary stale 响应时触发（SyncClient 应 pull 对齐）。
  Stream<void> get backupRelayStaleEvents => _backupRelayStaleController.stream;

  void start() {
    if (_running) return;
    _running = true;
    _sub = PeerConnectionManager.instance.controlEvents.listen(_onControl);
    _connSub = PeerConnectionManager.instance.events.listen(_onPeerConnection);
    _pushRetryTimer = Timer.periodic(_pushRetryInterval, (_) {
      unawaited(_retryAllPendingPushOutbox());
    });
    _relayRetryTimer = Timer.periodic(_pushRetryInterval, (_) {
      unawaited(_retryPendingBackupRelayDrain());
    });
    _log.info('SyncProtocolService started', tag: _tag);
    unawaited(SyncRoleService.announceLocalRole());
  }

  void stop() {
    _running = false;
    _sub?.cancel();
    _sub = null;
    _connSub?.cancel();
    _connSub = null;
    _pushRetryTimer?.cancel();
    _pushRetryTimer = null;
    _relayRetryTimer?.cancel();
    _relayRetryTimer = null;
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
          await _retryPushOutboxForDevice(peer!.deviceId!, bypassBackoff: true);
        }
        return;
      }
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.backup) return;
      final primary = await AccountIdentityService.instance.primaryDevice();
      final peer = await PeerStorageService().getPeerById(peerId);
      if (primary != null && peer?.deviceId == primary.deviceId) {
        await _drainBackupRelayQueue(peerId, bypassBackoff: true);
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

  Future<bool> _isCommitOriginValid(String peerId, SyncEvent event) async {
    final peer = await PeerStorageService().getPeerById(peerId);
    final peerDeviceId = peer?.deviceId;
    if (peerDeviceId == null || peerDeviceId.isEmpty) return false;
    if (event.originDeviceId.isEmpty) return false;
    return event.originDeviceId == peerDeviceId;
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

    final peer = await PeerStorageService().getPeerById(event.peerId);
    if (peer?.deviceId != null && peer!.deviceId != remoteDeviceId) {
      _log.warning(
        'Ignoring sync_role_announce: peer device_id mismatch (peer=${peer.deviceId}, payload=$remoteDeviceId)',
        tag: _tag,
      );
      return;
    }

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

    await AccountIdentityService.instance.reconcileRemoteDeviceRole(
      remoteDeviceId: remoteDeviceId,
      announcedRole: DeviceRole.fromWire(data['role'] as String?),
      deviceName: data['device_name'] as String?,
    );

    if (data.containsKey('elected_primary_device_id')) {
      final elected = data['elected_primary_device_id'] as String? ?? '';
      final updated = await _db.getOwnedDeviceByDeviceId(remoteDeviceId);
      if (updated?.role == DeviceRole.primary) {
        await AccountIdentityService.instance.applyRemoteUserElectedPrimary(
          elected.isEmpty ? null : elected,
        );
      } else if (elected.isEmpty) {
        final currentElected =
            await AccountIdentityService.instance.userElectedPrimaryDeviceId();
        if (currentElected == remoteDeviceId) {
          await AccountIdentityService.instance.applyRemoteUserElectedPrimary(null);
        }
      }
    }
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

    final payloadDeviceId = data['device_id'] as String?;
    if (payloadDeviceId == null || payloadDeviceId.isEmpty) return;
    final peer = await PeerStorageService().getPeerById(peerId);
    if (peer?.deviceId != null && peer!.deviceId != payloadDeviceId) {
      _log.warning('Ignoring sync_trust_accept: device_id mismatch', tag: _tag);
      return;
    }

    final roleWire = data['role'] as String?;
    await DeviceTrustService.instance.registerTrustedRemoteDevice(
      deviceId: payloadDeviceId,
      deviceName: data['device_name'] as String? ?? 'Device',
      transportPublicKey: Uint8List.fromList(pub),
      fingerprint: data['transport_fingerprint'] as String? ?? '',
      role: roleWire != null ? DeviceRole.fromWire(roleWire) : null,
    );
    _log.info('Registered trusted device via sync_trust_accept', tag: _tag);
  }

  Future<void> _handleHello(String peerId, Map<String, dynamic> data) async {
    if (!await _isOwnedAccountPeer(peerId)) return;
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
    if (role == DeviceRole.primary) {
      if (!await AccountIdentityService.instance.isCanonicalPrimary()) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_query_resp',
          'request_id': requestId,
          'error': 'not_canonical_primary',
          'events': <Map<String, dynamic>>[],
        });
        return;
      }
    } else if (role != DeviceRole.backup) {
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

      if (!await _isCommitOriginValid(peerId, event)) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_commit_resp',
          'request_id': requestId,
          'ok': false,
          'error': 'origin_device_mismatch',
        });
        return;
      }

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
            await _db.markBackupRelayAcked(event.eventId);
          } else if (relayResp['stale'] == true) {
            await _resolveStaleBackupRelay(event, rowId: event.eventId);
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

        // Primary 不可达：仅入 relay 队列，不在 Backup 本地 apply，避免多 Backup 视图分叉。
        await _db.enqueueBackupRelayEvent(
          id: event.eventId,
          payloadJson: jsonEncode(eventMap),
        );
        await PeerConnectionManager.instance.sendControl(
          peerId,
          SyncCommitResult.pendingRelayOk().toCommitResponse(requestId: requestId),
        );
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

  void _signalBackupRelayStale() {
    _backupRelayStaleController.add(null);
  }

  @visibleForTesting
  void signalBackupRelayStaleForTest() => _signalBackupRelayStale();

  /// Pull 对齐 Primary 后，丢弃已被本地状态覆盖的 stale relay 行。
  Future<void> reconcilePendingBackupRelayAfterPull() async {
    final role = await AccountIdentityService.instance.localDeviceRole();
    if (role != DeviceRole.backup) return;

    final pending = await _db.listPendingBackupRelay(limit: 200);
    for (final row in pending) {
      final rowId = row['id'] as String;
      final payloadRaw = row['payload'] as String? ?? '';
      try {
        final event = SyncEvent.fromJson(
          jsonDecode(payloadRaw) as Map<String, dynamic>,
        );
        if (await SyncEngine.instance.isEventSupersededByLocalState(event)) {
          await _db.markBackupRelayAcked(rowId);
          _log.info('Discarded superseded backup relay row ${event.eventId}', tag: _tag);
        }
      } catch (_) {
        await _db.markBackupRelayAcked(rowId);
      }
    }
  }

  Future<void> _resolveStaleBackupRelay(SyncEvent event, {required String rowId}) async {
    if (await SyncEngine.instance.isEventSupersededByLocalState(event)) {
      await _db.markBackupRelayAcked(rowId);
      return;
    }
    _log.warning(
      'Backup relay stale for ${event.eventId}, scheduling pull to reconcile',
      tag: _tag,
    );
    _signalBackupRelayStale();
  }

  Future<void> _retryPendingBackupRelayDrain() async {
    if (!_running) return;
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.backup) return;
      final primary = await AccountIdentityService.instance.primaryDevice();
      if (primary == null) return;
      final primaryPeerId = await _findPairedPeerId(primary.deviceId);
      if (primaryPeerId == null) return;
      if (PeerConnectionManager.instance.getPeerState(primaryPeerId) !=
          PeerConnectionState.connected) {
        return;
      }
      await _drainBackupRelayQueue(primaryPeerId);
    } catch (e) {
      _log.warning('Periodic backup relay retry failed: $e', tag: _tag);
    }
  }

  Future<void> _drainBackupRelayQueue(
    String primaryPeerId, {
    bool bypassBackoff = false,
  }) async {
    final pending = await _db.listPendingBackupRelay(
      limit: 50,
      bypassBackoff: bypassBackoff,
    );
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
      if (SyncCommitResult.shouldAckBackupRelayResponse(resp)) {
        final event = SyncEvent.fromJson(eventMap);
        await SyncEngine.instance.commitEventAsStorageRelay(event);
        await _db.markBackupRelayAcked(rowId);
      } else if (resp?['ok'] == true && resp?['stale'] == true) {
        final event = SyncEvent.fromJson(eventMap);
        await _resolveStaleBackupRelay(event, rowId: rowId);
      } else {
        await _db.scheduleBackupRelayRetry(rowId);
        _log.warning(
          'Backup relay drain deferred for $rowId: ${resp?['error'] ?? 'unknown'}',
          tag: _tag,
        );
        break;
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

    final primary = await AccountIdentityService.instance.primaryDevice();
    final peer = await PeerStorageService().getPeerById(peerId);
    final senderDeviceId = peer?.deviceId;
    if (primary == null ||
        senderDeviceId == null ||
        senderDeviceId != primary.deviceId) {
      _log.warning(
        'Ignoring sync_push from non-primary peer $peerId (sender=$senderDeviceId, primary=${primary?.deviceId})',
        tag: _tag,
      );
      return;
    }

    final eventsRaw = (data['events'] as List?) ?? const [];
    final events = eventsRaw
        .whereType<Map>()
        .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final result = await SyncEngine.instance.applyPushEvents(events);
    final pushId = data['push_id'] as String?;
    if (pushId != null && pushId.isNotEmpty) {
      if (!result.allApplied) {
        _log.warning(
          'sync_push partial apply failure from primary $peerId: ${result.failedEventIds}',
          tag: _tag,
        );
      }
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push_ack',
        'push_id': pushId,
        'ok': result.allApplied,
        if (result.failedEventIds.isNotEmpty) 'failed_event_ids': result.failedEventIds,
      });
    }
  }

  Future<void> _handlePushAck(Map<String, dynamic> data) async {
    final pushId = data['push_id'] as String?;
    if (pushId == null || pushId.isEmpty) return;

    if (data['ok'] == true) {
      await _db.markSyncPushAcked(pushId);
      return;
    }

    final failedRaw = data['failed_event_ids'] as List?;
    final failedIds = failedRaw?.map((e) => e.toString()).toList() ?? const <String>[];
    await _resolveFailedSyncPush(pushId, failedEventIds: failedIds);
  }

  /// Primary：根据接收方 ack 修剪 outbox；全失败时指数退避，超限 dead-letter。
  Future<void> _resolveFailedSyncPush(
    String pushId, {
    required List<String> failedEventIds,
  }) async {
    final row = await _db.getSyncPushOutboxRow(pushId);
    if (row == null || (row['acked'] as int? ?? 0) == 1) return;

    final payloadRaw = row['payload'] as String? ?? '[]';
    List<dynamic> eventsJson;
    try {
      eventsJson = jsonDecode(payloadRaw) as List<dynamic>;
    } catch (_) {
      await _db.markSyncPushDeadLetter(pushId);
      _log.warning('Dead-lettered corrupt sync push payload $pushId', tag: _tag);
      return;
    }

    if (failedEventIds.isEmpty) {
      await _maybeDeadLetterSyncPush(pushId, row);
      return;
    }

    final failedSet = failedEventIds.toSet();
    final remaining = eventsJson
        .whereType<Map>()
        .where((e) => failedSet.contains(e['event_id']?.toString()))
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    if (remaining.isEmpty) {
      await _db.markSyncPushAcked(pushId);
      return;
    }

    if (remaining.length == eventsJson.length) {
      final deadLettered = await _maybeDeadLetterSyncPush(pushId, row);
      if (deadLettered) return;
    }

    await _db.updateSyncPushPayload(pushId, jsonEncode(remaining));
    await _db.scheduleSyncPushRetry(pushId);
  }

  Future<bool> _maybeDeadLetterSyncPush(
    String pushId,
    Map<String, dynamic> row,
  ) async {
    final count = row['retry_count'] as int? ?? 0;
    if (count + 1 >= SyncPushBackoff.maxDeadLetterRetries) {
      await _db.markSyncPushDeadLetter(pushId);
      _log.warning(
        'Dead-lettered sync push $pushId after ${count + 1} retries',
        tag: _tag,
      );
      return true;
    }
    await _db.scheduleSyncPushRetry(pushId);
    return false;
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
      final sent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push',
        'push_id': pushId,
        'events': eventsJson,
      });
      if (!sent) {
        await _db.scheduleSyncPushRetry(pushId);
      }
    }
  }

  Future<void> _retryAllPendingPushOutbox() async {
    if (!_running) return;
    try {
      if (!await AccountIdentityService.instance.isCanonicalPrimary()) return;
      final owned = await AccountIdentityService.instance.ownedDevices();
      for (final d in owned) {
        if (d.isLocal) continue;
        if (d.role != DeviceRole.backup && d.role != DeviceRole.app) continue;
        await _retryPushOutboxForDevice(d.deviceId);
      }
    } catch (e) {
      _log.warning('Periodic push outbox retry failed: $e', tag: _tag);
    }
  }

  Future<void> _retryPushOutboxForDevice(
    String targetDeviceId, {
    bool bypassBackoff = false,
  }) async {
    final pending = await _db.listPendingSyncPushForDevice(
      targetDeviceId,
      bypassBackoff: bypassBackoff,
    );
    for (final row in pending) {
      final pushId = row['id'] as String;
      final retryCount = row['retry_count'] as int? ?? 0;
      if (retryCount >= SyncPushBackoff.maxDeadLetterRetries) {
        await _db.markSyncPushDeadLetter(pushId);
        _log.warning('Dead-lettered sync push $pushId (retry cap)', tag: _tag);
        continue;
      }
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
      final sent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_push',
        'push_id': pushId,
        'events': eventsJson,
      });
      if (!sent) {
        await _db.scheduleSyncPushRetry(pushId);
        break;
      }
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
    if (blobKey == null || !BlobPathUtils.isValidRelativeStoragePath(blobKey)) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_blob_resp',
        'request_id': requestId,
        'error': blobKey == null ? 'missing_blob_key' : 'invalid_blob_key',
      });
      return;
    }

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
      final blobKey = data['blob_key'] as String?;
      if (blobKey == null || !BlobPathUtils.isValidRelativeStoragePath(blobKey)) {
        await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_blob_push_ack',
          'request_id': requestId,
          'ok': false,
          'error': blobKey == null ? 'missing_blob_key' : 'invalid_blob_key',
        });
        return;
      }
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
    final peer = await PeerStorageService().getPeerById(peerId);
    final callerDeviceId = peer?.deviceId;
    final callerRecord = callerDeviceId != null
        ? await _db.getOwnedDeviceByDeviceId(callerDeviceId)
        : null;
    final callerRole = callerRecord?.role ?? DeviceRole.app;
    if (!DeviceRpcPolicy.callerMayInvoke(method, callerRole)) {
      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'device_rpc_resp',
        'request_id': requestId,
        'error': 'rpc_caller_not_allowed',
      });
      return;
    }

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

  /// 测试专用：同步分发 control 消息（等待 commit 等关键 handler 完成）。
  @visibleForTesting
  Future<void> dispatchControlForTest(String peerId, Map<String, dynamic> data) async {
    final type = data['type'] as String? ?? '';
    switch (type) {
      case 'sync_commit':
        await _handleCommit(peerId, data);
        return;
      case 'sync_commit_resp':
        _completeCommitWaiter(data);
        return;
      case 'sync_query_resp':
        _completeQueryWaiter(data);
        return;
      case 'sync_push':
        await _handlePush(peerId, data);
        return;
      case 'sync_push_ack':
        await _handlePushAck(data);
        return;
      case 'sync_trust_accept':
        await _handleTrustAccept(peerId, data);
        return;
      case 'sync_role_announce':
        await _handleRoleAnnounce(PeerControlEvent(peerId: peerId, data: data));
        return;
      case 'sync_query':
        await _handleQuery(peerId, data);
        return;
      case 'device_rpc':
        await _handleDeviceRpc(peerId, data);
        return;
      default:
        _onControl(PeerControlEvent(peerId: peerId, data: data));
    }
  }

  @visibleForTesting
  Future<void> drainBackupRelayQueueForTest(String primaryPeerId) =>
      _drainBackupRelayQueue(primaryPeerId);

  @visibleForTesting
  Future<void> onStoragePeerConnectedForTest(String peerId) =>
      _onStoragePeerConnected(peerId);
}

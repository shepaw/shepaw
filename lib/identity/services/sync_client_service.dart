import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../peer/services/peer_connection.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import 'account_identity_service.dart';
import 'blob_sync_service.dart';
import 'device_trust_service.dart';
import 'sync_engine.dart';
import 'sync_protocol_service.dart';

/// App / Backup 设备：连接 Primary 后拉取同步、提交 outbound 队列。
class SyncClientService {
  SyncClientService._();
  static final SyncClientService instance = SyncClientService._();

  static const _tag = 'SyncClient';
  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _uuid = const Uuid();

  StreamSubscription? _connSub;
  bool _running = false;
  bool _pulling = false;

  void start() {
    if (_running) return;
    _running = true;
    _connSub = PeerConnectionManager.instance.events.listen(_onConnEvent);
    _log.info('SyncClientService started', tag: _tag);
  }

  void stop() {
    _running = false;
    _connSub?.cancel();
    _connSub = null;
  }

  void _onConnEvent(PeerConnectionEvent event) {
    if (event.type == PeerConnectionEventType.connected) {
      unawaited(_onPeerConnected(event.peerId));
    }
  }

  Future<void> _onPeerConnected(String peerId) async {
    try {
      await AccountIdentityService.instance.ensureInitialized();
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role == DeviceRole.primary) return;

      final peer = await PeerStorageService().getPeerById(peerId);
      if (peer == null) return;

      final primary = await AccountIdentityService.instance.primaryDevice();
      if (primary == null) return;

      // 若连接的是 Primary（按 deviceId 匹配），发起同步。
      if (peer.deviceId != primary.deviceId) return;

      await _sendTrustAccept(peerId);
      await pullFromPeer(peerId);
      await _flushOutbound(peerId);
    } catch (e) {
      _log.warning('Sync on connect failed: $e', tag: _tag);
    }
  }

  Future<void> _sendTrustAccept(String peerId) async {
    final payload = await DeviceTrustService.instance.buildTrustAcceptPayload();
    await PeerConnectionManager.instance.sendControl(peerId, payload);
  }

  /// 手动触发从 Primary 拉取（设置页 / 下拉刷新）。
  Future<void> pullFromPrimary() async {
    final peerId = await _primaryPeerId();
    if (peerId == null) {
      throw StateError('Primary device not paired or offline');
    }
    await pullFromPeer(peerId);
  }

  Future<void> pullFromPeer(String peerId) async {
    if (_pulling) return;
    _pulling = true;
    try {
      var cursor = await SyncEngine.instance.getLocalCursorMs();
      const pageSize = 50;

      for (var page = 0; page < 200; page++) {
        final requestId = _uuid.v4();
        final sent = await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_query',
          'request_id': requestId,
          'since_ms': cursor,
          'limit': pageSize,
        });
        if (!sent) break;

        final resp = await SyncProtocolService.instance.waitQueryResponse(
          requestId,
          timeout: const Duration(seconds: 30),
        );
        if (resp == null) break;

        final eventsRaw = (resp['events'] as List?) ?? const [];
        if (eventsRaw.isEmpty) break;

        final events = eventsRaw
            .whereType<Map>()
            .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList();

        cursor = await SyncEngine.instance.applyEvents(events);
        if (events.length < pageSize) break;
      }
    } finally {
      _pulling = false;
    }
  }

  Future<void> _flushOutbound(String peerId) async {
    final pending = await _db.listPendingOutbound(limit: 50);
    for (final row in pending) {
      final requestId = _uuid.v4();
      Map<String, dynamic> eventJson;
      try {
        eventJson = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      } catch (_) {
        continue;
      }

      await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit',
        'request_id': requestId,
        'event': eventJson,
      });

      final resp = await SyncProtocolService.instance.waitCommitResponse(
        requestId,
        timeout: const Duration(seconds: 15),
      );
      if (resp?['ok'] == true) {
        await _db.markOutboundAcked(row['id'] as String);
        await _maybePushBlobForEvent(eventJson);
      }
    }
  }

  Future<void> _maybePushBlobForEvent(Map<String, dynamic> eventJson) async {
    if (eventJson['domain'] != 'message') return;
    final payload = eventJson['payload'];
    if (payload is! Map) return;

    final metaRaw = payload['metadata'];
    Map<String, dynamic>? meta;
    if (metaRaw is String && metaRaw.isNotEmpty) {
      try {
        meta = Map<String, dynamic>.from(jsonDecode(metaRaw) as Map);
      } catch (_) {
        return;
      }
    } else if (metaRaw is Map) {
      meta = Map<String, dynamic>.from(metaRaw);
    }

    final path = meta?['path'] as String?;
    if (path == null || path.isEmpty) return;

    try {
      await BlobSyncService.instance.pushBlobToPrimary(path);
    } catch (e) {
      _log.warning('Blob push after commit failed: $e', tag: _tag);
    }
  }

  Future<String?> _primaryPeerId() async {
    final primary = await AccountIdentityService.instance.primaryDevice();
    if (primary == null) return null;
    final peers = await PeerStorageService().loadAllPeers();
    for (final p in peers) {
      if (p.deviceId == primary.deviceId) return p.id;
    }
    return null;
  }
}

/// 供 outbound 队列使用的 helper：App 设备本地发消息后 enqueue。
Future<void> enqueueMessageSyncEvent(Map<String, dynamic> messageRow, String originDeviceId) async {
  final db = LocalDatabaseService();
  final event = SyncEvent.messageEvent(messageRow: messageRow, originDeviceId: originDeviceId);
  await db.enqueueOutboundEvent(
    id: event.eventId,
    domain: event.domain,
    payloadJson: event.toJsonString(),
  );
}

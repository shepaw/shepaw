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
import 'sync_local_write_hook.dart';
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
  Future<void> _pullChain = Future.value();

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

      if (peer.deviceId != primary.deviceId) return;

      await _sendTrustAccept(peerId);
      await pullFromPeer(peerId);
      await _flushOutbound(peerId);
      await _flushBlobOutbound(peerId);
    } catch (e) {
      _log.warning('Sync on connect failed: $e', tag: _tag);
    }
  }

  Future<void> _sendTrustAccept(String peerId) async {
    final payload = await DeviceTrustService.instance.buildTrustAcceptPayload();
    await PeerConnectionManager.instance.sendControl(peerId, payload);
  }

  Future<void> pullFromPrimary() async {
    final peerId = await _primaryPeerId();
    if (peerId == null) {
      throw StateError('Primary device not paired or offline');
    }
    await pullFromPeer(peerId);
  }

  /// 从 Primary 完整同步：拉取 + 提交 outbound + blob 队列。
  Future<void> syncWithPrimary() async {
    final peerId = await _primaryPeerId();
    if (peerId == null) {
      throw StateError('Primary device not paired or offline');
    }
    await syncWithPeer(peerId);
  }

  Future<void> syncWithPeer(String peerId) async {
    await pullFromPeer(peerId);
    await flushOutboundToPeer(peerId);
    await flushBlobOutboundToPeer(peerId);
  }

  Future<void> flushOutboundToPeer(String peerId) async {
    await _flushOutbound(peerId);
  }

  Future<void> flushBlobOutboundToPeer(String peerId) async {
    await _flushBlobOutbound(peerId);
  }

  Future<void> pullFromPeer(String peerId) {
    _pullChain = _pullChain.then((_) => _pullFromPeerImpl(peerId));
    return _pullChain;
  }

  Future<void> _pullFromPeerImpl(String peerId) async {
    await _pullDomain(peerId, domain: 'message');
    await _pullDomain(peerId, domain: 'channel');
    await _pullDomain(peerId, domain: 'channel_member');
    await _pullDomain(peerId, domain: 'agent');
    await _pullDomain(peerId, domain: 'she_memory');
    await _pullDomain(peerId, domain: 'cognition');
  }

  Future<void> _pullDomain(String peerId, {required String domain}) async {
    var cursor = switch (domain) {
      'message' => await SyncEngine.instance.getMessageCursorMs(),
      'channel' => await SyncEngine.instance.getChannelCursorMs(),
      'channel_member' => await SyncEngine.instance.getMemberCursorMs(),
      'agent' => await SyncEngine.instance.getAgentCursorMs(),
      'she_memory' => await SyncEngine.instance.getSheMemoryCursorMs(),
      'cognition' => await SyncEngine.instance.getCognitionCursorMs(),
      _ => 0,
    };
    const pageSize = 50;

    for (var page = 0; page < 200; page++) {
      final requestId = _uuid.v4();
      final sent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_query',
        'request_id': requestId,
        'domain': domain,
        'since_ms': cursor,
        'limit': pageSize,
      });
      if (!sent) break;

      Map<String, dynamic> resp;
      try {
        resp = await SyncProtocolService.instance.waitQueryResponse(
          requestId,
          timeout: const Duration(seconds: 30),
        );
      } on SyncQueryTimeoutException {
        _log.warning('Sync query timeout for domain=$domain', tag: _tag);
        break;
      }

      final eventsRaw = (resp['events'] as List?) ?? const [];
      if (eventsRaw.isEmpty) break;

      final events = eventsRaw
          .whereType<Map>()
          .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
          .toList();

      if (domain == 'message') {
        cursor = await SyncEngine.instance.applyMessageEvents(events);
      } else if (domain == 'channel') {
        cursor = await SyncEngine.instance.applyChannelEvents(events);
      } else if (domain == 'channel_member') {
        cursor = await SyncEngine.instance.applyMemberEvents(events);
      } else if (domain == 'agent') {
        cursor = await SyncEngine.instance.applyAgentEvents(events);
      } else if (domain == 'she_memory') {
        cursor = await SyncEngine.instance.applySheMemoryEvents(events);
      } else if (domain == 'cognition') {
        cursor = await SyncEngine.instance.applyCognitionEvents(events);
      }

      if (events.length < pageSize) break;
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
        final blobPath = SyncLocalWriteHook.attachmentPathFromEventJson(eventJson);
        if (blobPath != null) {
          await _db.enqueueBlobOutbound(relativePath: blobPath);
        }
      }
    }
    await _flushBlobOutbound(peerId);
  }

  Future<void> _flushBlobOutbound(String peerId) async {
    final pending = await _db.listPendingBlobOutbound(limit: 20);
    for (final row in pending) {
      final path = row['relative_path'] as String? ?? '';
      if (path.isEmpty) continue;
      try {
        await BlobSyncService.instance.pushBlobToPrimary(path, peerId: peerId);
        await _db.markBlobOutboundAcked(path);
      } catch (e) {
        _log.warning('Blob outbound retry failed for $path: $e', tag: _tag);
      }
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

  /// 待同步队列统计（App 设备 UI 展示用）。
  Future<SyncPendingCounts> pendingCounts() async {
    return SyncPendingCounts(
      events: await _db.countPendingOutbound(),
      blobs: await _db.countPendingBlobOutbound(),
    );
  }
}

class SyncPendingCounts {
  final int events;
  final int blobs;

  const SyncPendingCounts({required this.events, required this.blobs});

  int get total => events + blobs;
  bool get hasPending => total > 0;
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

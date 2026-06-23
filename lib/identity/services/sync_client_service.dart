import 'dart:async';
import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../peer/models/paired_peer.dart';
import '../../peer/services/peer_connection.dart';
import '../../peer/services/peer_connection_manager.dart';
import '../../peer/services/peer_storage_service.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import '../models/device_role.dart';
import '../models/sync_event.dart';
import '../utils/sync_query_limits.dart';
import '../models/sync_commit_result.dart';
import '../models/sync_pull_exception.dart';
import 'account_identity_service.dart';
import 'blob_sync_service.dart';
import 'device_trust_service.dart';
import 'storage_device_service.dart';
import 'sync_engine.dart';
import 'sync_local_write_hook.dart';
import 'sync_protocol_service.dart';
import 'sync_role_service.dart';

/// App / Backup 设备：连接 Primary 后拉取同步、提交 outbound 队列。
class SyncClientService {
  SyncClientService._();
  static final SyncClientService instance = SyncClientService._();

  static const _tag = 'SyncClient';
  static const _outboundRetryInterval = Duration(minutes: 1);
  final _log = LoggerService();
  final _db = LocalDatabaseService();
  final _uuid = const Uuid();

  StreamSubscription? _connSub;
  StreamSubscription? _relayStaleSub;
  Timer? _outboundRetryTimer;
  bool _running = false;
  Future<void> _pullChain = Future.value();
  final _staleCommitController = StreamController<void>.broadcast();

  /// Primary 因版本较新拒绝本地 commit 时触发（已自动 pull 刷新）。
  Stream<void> get staleCommitEvents => _staleCommitController.stream;

  void start() {
    if (_running) return;
    _running = true;
    _connSub = PeerConnectionManager.instance.events.listen(_onConnEvent);
    _relayStaleSub = SyncProtocolService.instance.backupRelayStaleEvents.listen((_) {
      unawaited(_pullFromPrimaryAfterRelayStale());
    });
    _outboundRetryTimer = Timer.periodic(_outboundRetryInterval, (_) {
      unawaited(_retryPendingOutboundIfConnected());
    });
    _log.info('SyncClientService started', tag: _tag);
  }

  Future<void> awaitIdle() => _pullChain;

  @visibleForTesting
  Future<void> pullFromPrimaryAfterRelayStaleForTest() =>
      _pullFromPrimaryAfterRelayStale();

  void stop() {
    _running = false;
    _outboundRetryTimer?.cancel();
    _outboundRetryTimer = null;
    _relayStaleSub?.cancel();
    _relayStaleSub = null;
    _connSub?.cancel();
    _connSub = null;
    _pullChain = Future.value();
  }

  Future<void> _pullFromPrimaryAfterRelayStale() async {
    try {
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role != DeviceRole.backup) return;
      final peerId = await StorageDeviceService.firstConnectedPrimaryPeerId();
      if (peerId == null) return;
      await pullFromPeer(peerId);
      await SyncProtocolService.instance.reconcilePendingBackupRelayAfterPull();
      _log.info('Pulled from Primary after backup relay stale', tag: _tag);
    } catch (e) {
      _log.warning('Pull after backup relay stale failed: $e', tag: _tag);
    }
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

      if (!await StorageDeviceService.isStorageDeviceId(peer.deviceId)) return;

      await _sendTrustAccept(peerId);
      await SyncRoleService.announceLocalRole();
      final pullPeerId = await StorageDeviceService.connectedPrimaryPullPeerId();
      if (pullPeerId != null) {
        await pullFromPeer(pullPeerId);
      }
      await _flushOutbound(peerId);
      await _flushBlobOutbound();
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

  /// 全量 resync：重置游标与 entity state 后从 Primary 重新拉取并提交 outbound。
  Future<void> fullResyncFromPrimary() async {
    await SyncEngine.instance.resetForFullResync();
    await syncWithPrimary();
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
    await _flushBlobOutbound();
  }

  Future<void> pullFromPeer(String peerId) {
    _pullChain = _pullChain.then((_) => _pullFromPeerImpl(peerId));
    return _pullChain;
  }

  Future<void> _pullFromPeerImpl(String peerId) async {
    final failed = <String>[];
    for (final domain in SyncEngine.syncDomains) {
      final ok = await _pullDomain(peerId, domain: domain);
      if (!ok) failed.add(domain);
    }
    await SyncEngine.instance.pruneOldTombstones();
    await _db.pruneAckedSyncQueues();
    if (failed.isNotEmpty) {
      throw SyncPullException(
        'Sync pull incomplete for domains: ${failed.join(', ')}',
        failed,
      );
    }
  }

  Future<void> _retryPendingOutboundIfConnected() async {
    if (!_running) return;
    try {
      await _pullChain;
      await AccountIdentityService.instance.ensureInitialized();
      final role = await AccountIdentityService.instance.localDeviceRole();
      if (role == DeviceRole.primary) return;

      final pending = await pendingCounts();
      if (!pending.hasPending) return;

      final peerId = await _primaryPeerId();
      if (peerId == null) return;
      if (PeerConnectionManager.instance.getPeerState(peerId) !=
          PeerConnectionState.connected) {
        return;
      }

      await _flushOutbound(peerId);
      await _flushBlobOutbound();
    } catch (e) {
      _log.warning('Periodic outbound retry failed: $e', tag: _tag);
    }
  }

  Future<bool> _pullDomain(String peerId, {required String domain}) async {
    const pageSize = SyncQueryLimits.clientPageSize;
    const maxPages = SyncQueryLimits.maxClientPages;

    while (true) {
      var cursor = await SyncEngine.instance.getDomainCursor(domain);
      var truncated = false;

      for (var page = 0; page < maxPages; page++) {
        final requestId = _uuid.v4();
        final sent = await PeerConnectionManager.instance.sendControl(peerId, {
          'type': 'sync_query',
          'request_id': requestId,
          'domain': domain,
          'since_ms': cursor.wallTimeMs,
          'since_event_id': cursor.lastEventId,
          'limit': pageSize,
        });
        if (!sent) {
          _log.warning('Sync query send failed for domain=$domain', tag: _tag);
          return false;
        }

        Map<String, dynamic> resp;
        try {
          resp = await SyncProtocolService.instance.waitQueryResponse(
            requestId,
            timeout: const Duration(seconds: 30),
          );
        } on SyncQueryTimeoutException {
          _log.warning('Sync query timeout for domain=$domain', tag: _tag);
          return false;
        }

        if (resp['error'] != null) {
          _log.warning('Sync query error for domain=$domain: ${resp['error']}', tag: _tag);
          return false;
        }

        final eventsRaw = (resp['events'] as List?) ?? const [];
        if (eventsRaw.isEmpty) break;

        final parsed = eventsRaw
            .whereType<Map>()
            .map((e) => SyncEvent.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        final events = await SyncEngine.instance.filterApplyableEvents(parsed, cursor);
        if (events.isEmpty) break;

        cursor = switch (domain) {
          'message' => (await SyncEngine.instance.applyMessageEvents(events)),
          'channel' => (await SyncEngine.instance.applyChannelEvents(events)),
          'channel_member' => (await SyncEngine.instance.applyMemberEvents(events)),
          'agent' => (await SyncEngine.instance.applyAgentEvents(events)),
          'she_memory' => (await SyncEngine.instance.applySheMemoryEvents(events)),
          'cognition' => (await SyncEngine.instance.applyCognitionEvents(events)),
          'agent_memory' => (await SyncEngine.instance.applyAgentMemoryEvents(events)),
          _ => cursor,
        };

        final hasMore = resp['has_more'] == true;
        if (!hasMore && eventsRaw.length < pageSize) break;
        if (!hasMore) break;
        if (page == maxPages - 1) {
          truncated = true;
        }
      }

      if (!truncated) return true;
      _log.info('Sync pull continuing after page cap for domain=$domain', tag: _tag);
    }
  }

  Future<void> _flushOutbound(String peerId) async {
    await _pullChain;
    final pending = await _db.listPendingOutbound(limit: 50);
    var hadStaleCommit = false;
    for (final row in pending) {
      final requestId = _uuid.v4();
      final rowId = row['id'] as String;
      Map<String, dynamic> eventJson;
      try {
        eventJson = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
      } catch (_) {
        await _db.discardOutboundEvent(rowId);
        continue;
      }

      final sent = await PeerConnectionManager.instance.sendControl(peerId, {
        'type': 'sync_commit',
        'request_id': requestId,
        'event': eventJson,
      });
      if (!sent) {
        _log.warning('Sync commit send failed, stopping outbound flush', tag: _tag);
        break;
      }

      final resp = await SyncProtocolService.instance.waitCommitResponse(
        requestId,
        timeout: const Duration(seconds: 15),
      );
      if (SyncCommitResult.shouldAckOutboundCommitResponse(resp)) {
        await _db.markOutboundAcked(rowId);
        final stale = resp?['stale'] == true;
        if (stale) {
          hadStaleCommit = true;
        }
        final applied = resp?['applied'] == true ||
            (resp?['applied'] == null && resp?['stale'] != true);
        final blobPath = SyncLocalWriteHook.attachmentPathFromEventJson(eventJson);
        if (blobPath != null && applied && !stale) {
          await _db.enqueueBlobOutbound(relativePath: blobPath);
        }
      }
    }
    if (hadStaleCommit) {
      _staleCommitController.add(null);
      unawaited(pullFromPeer(peerId));
    }
    await _flushBlobOutbound();
  }

  Future<void> _flushBlobOutbound() async {
    final primaryPeerId = await StorageDeviceService.firstConnectedPrimaryPeerId();
    if (primaryPeerId == null) {
      _log.info('Skipping blob outbound flush: Primary not connected', tag: _tag);
      return;
    }
    final pending = await _db.listPendingBlobOutbound(limit: 20);
    for (final row in pending) {
      final path = row['relative_path'] as String? ?? '';
      if (path.isEmpty) continue;
      try {
        await BlobSyncService.instance.pushBlobToPrimary(path, peerId: primaryPeerId);
        await _db.markBlobOutboundAcked(path);
      } catch (e) {
        _log.warning('Blob outbound retry failed for $path: $e', tag: _tag);
      }
    }
  }

  @visibleForTesting
  Future<void> onStoragePeerConnectedForTest(String peerId) => _onPeerConnected(peerId);

  /// 从 Primary 拉取同步；不回退 Backup，避免缺少 pending relay 的副本视图。
  Future<String?> _primaryPeerId() => StorageDeviceService.connectedPrimaryPullPeerId();

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

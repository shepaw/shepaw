import 'dart:async';

import 'package:flutter/foundation.dart';

import '../peer/services/peer_connection.dart'
    show PeerConnectionEvent, PeerConnectionEventType;
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../service_locator.dart';
import '../services/logger_service.dart';
import '../services/remote_agent_service.dart';
import '../storage/device_identity.dart';
import '../storage/store_protocol.dart' show TrustLevel;
import 'digest_service.dart';
import 'presence_profile.dart';
import 'she_network_protocol.dart';

/// she.presence 广播与缓存（方案 §8.1：只广播类别，不暴露名单）。
class PresenceService {
  PresenceService._();
  static final PresenceService instance = PresenceService._();

  static const _tag = 'ShePresence';
  final _log = LoggerService();
  final _peerStorage = PeerStorageService();
  final _manager = PeerConnectionManager.instance;

  final _cache = <String, ShePresence>{};
  StreamSubscription<PeerControlEvent>? _controlSub;
  StreamSubscription<PeerConnectionEvent>? _connSub;
  StreamSubscription<void>? _agentsSub;
  bool _started = false;

  Map<String, ShePresence> get known => Map.unmodifiable(_cache);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _controlSub = _manager.controlEvents.listen(_onControl);
    _connSub = _manager.events.listen((e) {
      if (e.type == PeerConnectionEventType.connected) {
        unawaited(_onPeerConnected(e.peerId));
      } else if (e.type == PeerConnectionEventType.disconnected) {
        unawaited(_onPeerDisconnected(e.peerId));
      }
    });
    try {
      if (getIt.isRegistered<RemoteAgentService>()) {
        _agentsSub = getIt<RemoteAgentService>().agentsChanged.listen((_) {
          unawaited(broadcastNow());
        });
      }
    } catch (_) {}
    unawaited(broadcastNow());
  }

  Future<void> stop() async {
    await _controlSub?.cancel();
    _controlSub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _agentsSub?.cancel();
    _agentsSub = null;
    _started = false;
  }

  @visibleForTesting
  void putPresence(ShePresence p) => _cache[p.deviceId] = p;

  Future<ShePresence> buildLocalPresence(
      {String localizedSheName = 'She'}) async {
    final self = await DeviceIdentity.deviceId();
    final name = await DigestService.instance
        .localSheName(localizedDefault: localizedSheName);
    final profile = await _loadLocalProfile();
    return ShePresence(
      deviceId: self,
      sheName: name,
      online: true,
      agentCategories: profile.agentCategories,
      toolCategories: profile.toolCategories,
      agentCount: profile.agentCount,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<PresenceProfile> _loadLocalProfile() async {
    try {
      if (!getIt.isRegistered<RemoteAgentService>()) {
        return PresenceProfile.fallback;
      }
      final agents = await getIt<RemoteAgentService>().getAllAgents();
      return aggregatePresenceProfile(agents);
    } catch (e) {
      _log.debug('presence profile fallback: $e', tag: _tag);
      return PresenceProfile.fallback;
    }
  }

  Future<void> broadcastNow({String localizedSheName = 'She'}) async {
    final presence =
        await buildLocalPresence(localizedSheName: localizedSheName);
    // 本机也写入缓存，方便圈子 UI 展示自身画像
    _cache[presence.deviceId] = presence;
    final peers = await _peerStorage.loadAllPeers();
    for (final peer in peers) {
      if (peer.trustLevel != TrustLevel.owner) continue;
      try {
        await _manager.sendControl(
          peer.id,
          SheFrame(op: SheOp.presence, payload: presence.toJson()).toJson(),
        );
      } catch (e) {
        _log.warning('presence to ${peer.fingerprint} failed: $e', tag: _tag);
      }
    }
  }

  /// 按类别选委托目标：返回持有 [category] 的在线设备（不含本机）。
  Future<List<ShePresence>> routeByCategory(String category) async {
    final self = await DeviceIdentity.deviceId();
    return _cache.values
        .where((p) =>
            p.deviceId != self &&
            p.online &&
            (p.agentCategories.contains(category) ||
                p.toolCategories.contains(category)))
        .toList();
  }

  Future<void> _onPeerConnected(String peerId) async {
    try {
      final peer = await _peerStorage.getPeerById(peerId);
      if (peer == null || peer.trustLevel != TrustLevel.owner) return;
      await broadcastNow();
      await _manager.sendControl(
        peerId,
        SheFrame(op: SheOp.presenceQuery, payload: const {}).toJson(),
      );
    } catch (_) {}
  }

  Future<void> _onPeerDisconnected(String peerId) async {
    try {
      final peer = await _peerStorage.getPeerById(peerId);
      if (peer == null) return;
      final key = peer.fingerprint;
      final existing = _cache[key];
      if (existing == null) return;
      _cache[key] = ShePresence(
        deviceId: existing.deviceId,
        sheName: existing.sheName,
        online: false,
        agentCategories: existing.agentCategories,
        toolCategories: existing.toolCategories,
        agentCount: existing.agentCount,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  void _onControl(PeerControlEvent event) {
    final frame = SheFrame.tryParse(event.data);
    if (frame == null) return;
    unawaited(_handle(event.peerId, frame));
  }

  Future<void> _handle(String peerId, SheFrame frame) async {
    final peer = await _peerStorage.getPeerById(peerId);
    if (peer == null) return;
    if (!memorySheAllowed(peer.trustLevel)) {
      _log.warning('reject she.${frame.op} from friend $peerId', tag: _tag);
      return;
    }
    switch (frame.op) {
      case SheOp.presence:
        final p = ShePresence.fromJson(frame.payload);
        if (p.deviceId.isEmpty) {
          _cache[peer.fingerprint] = ShePresence(
            deviceId: peer.fingerprint,
            sheName: frame.payload['she_name'] as String? ?? 'She',
            online: true,
            agentCategories:
                (frame.payload['agent_categories'] as List?)?.cast<String>() ??
                    const [],
            toolCategories:
                (frame.payload['tool_categories'] as List?)?.cast<String>() ??
                    const [],
            agentCount: frame.payload['agent_count'] as int? ?? 0,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          );
        } else {
          _cache[p.deviceId] = p;
        }
        break;
      case SheOp.presenceQuery:
        final local = await buildLocalPresence();
        await _manager.sendControl(
          peerId,
          SheFrame(op: SheOp.presence, payload: local.toJson()).toJson(),
        );
        break;
    }
  }
}

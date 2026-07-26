import 'dart:async';

import '../peer/services/peer_connection.dart'
    show PeerConnectionEventType;
import '../peer/services/peer_connection_manager.dart';
import '../peer/services/peer_storage_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import '../storage/device_identity.dart';
import '../storage/store_protocol.dart' show TrustLevel;
import 'digest_service.dart';
import 'exchange_settings.dart';
import 'external_memory_store.dart';
import 'she_network_protocol.dart';

/// 记忆交换编排（方案 §8.2）：digest.offer 收发；每日至多一次 + 手动。
class MemoryExchangeService {
  MemoryExchangeService._();
  static final MemoryExchangeService instance = MemoryExchangeService._();

  static const _tag = 'MemoryExchange';
  static const _lastOfferKey = 'she_network.last_digest_offer_day';

  final _log = LoggerService();
  final _peerStorage = PeerStorageService();
  final _manager = PeerConnectionManager.instance;

  StreamSubscription? _controlSub;
  StreamSubscription? _connSub;
  bool _started = false;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    _controlSub = _manager.controlEvents.listen((e) {
      final frame = MemoryFrame.tryParse(e.data);
      if (frame == null) return;
      unawaited(_handleInbound(e.peerId, frame));
    });
    _connSub = _manager.events.listen((e) {
      if (e.type == PeerConnectionEventType.connected) {
        unawaited(checkAutoOffer());
      }
    });
  }

  Future<void> stop() async {
    await _controlSub?.cancel();
    _controlSub = null;
    await _connSub?.cancel();
    _connSub = null;
    _started = false;
  }

  /// 每日至多一次自动推送（连接触发）。
  Future<bool> checkAutoOffer() async {
    final settings = await ExchangeSettings.load();
    if (!settings.enabled) return false;
    final day = _todayKey();
    final last = await LocalDatabaseService().getUserValue(_lastOfferKey);
    if (last == day) return false;
    final ok = await offerToAllOwners(manual: false);
    if (ok) {
      await LocalDatabaseService().setUserValue(_lastOfferKey, day);
    }
    return ok;
  }

  /// 手动触发交换。
  Future<bool> offerToAllOwners({bool manual = true}) async {
    final settings = await ExchangeSettings.load();
    if (!settings.enabled) {
      _log.info('exchange disabled; skip offer', tag: _tag);
      return false;
    }
    final entries =
        await DigestService.instance.buildOutgoing(settings: settings);
    if (entries.isEmpty) {
      _log.info('no digest entries to offer', tag: _tag);
      return false;
    }
    final self = await DeviceIdentity.deviceId();
    final period = DigestService.instance.currentPeriod();
    final frame = MemoryFrame(
      op: MemoryOp.digestOffer,
      payload: <String, dynamic>{
        'from_device': self,
        'period': period,
        'entries': [for (final e in entries) e.toJson()],
      },
    );
    final peers = await _peerStorage.loadAllPeers();
    var sent = 0;
    for (final peer in peers) {
      if (peer.trustLevel != TrustLevel.owner) continue;
      try {
        final ok = await _manager.sendControl(peer.id, frame.toJson());
        if (ok) sent++;
      } catch (e) {
        _log.warning('digest.offer to ${peer.fingerprint} failed: $e',
            tag: _tag);
      }
    }
    if (manual && sent > 0) {
      await LocalDatabaseService().setUserValue(_lastOfferKey, _todayKey());
    }
    _log.info('digest.offer sent to $sent peers (${entries.length} entries)',
        tag: _tag);
    return sent > 0;
  }

  Future<void> _handleInbound(String peerId, MemoryFrame frame) async {
    final peer = await _peerStorage.getPeerById(peerId);
    if (peer == null) return;
    if (!memorySheAllowed(peer.trustLevel)) {
      _log.warning('reject memory.${frame.op} from friend $peerId', tag: _tag);
      return;
    }
    switch (frame.op) {
      case MemoryOp.digestOffer:
        final settings = await ExchangeSettings.load();
        if (!settings.enabled) return;
        final from = frame.payload['from_device'] as String? ?? peer.fingerprint;
        final period = frame.payload['period'] as String? ?? '';
        final raw = (frame.payload['entries'] as List?) ?? const [];
        final entries = <DigestEntry>[];
        for (final e in raw) {
          if (e is! Map) continue;
          final entry = DigestEntry.fromJson(Map<String, dynamic>.from(e));
          if (!DigestKind.isValid(entry.kind)) continue;
          if (!settings.kinds.contains(entry.kind)) continue; // 类别关闭则不入库
          entries.add(entry);
        }
        await ExternalMemoryStore.instance.appendOffer(
          fromDevice: from,
          period: period,
          entries: entries,
        );
        try {
          await _manager.sendControl(
            peerId,
            MemoryFrame(op: MemoryOp.digestAck, payload: {
              'accepted': entries.length,
              'from_device': await DeviceIdentity.deviceId(),
            }).toJson(),
          );
        } catch (_) {}
        break;
      case MemoryOp.digestAck:
        _log.info(
            'digest.ack from ${peer.fingerprint}: ${frame.payload}',
            tag: _tag);
        break;
    }
  }

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }
}

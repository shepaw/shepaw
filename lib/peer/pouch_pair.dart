import 'dart:async';

import 'package:uuid/uuid.dart';

import '../storage/pouch_role.dart';
import '../storage/store_service.dart';
import 'models/paired_peer.dart';
import 'models/pairing_payload.dart';
import 'pouch_turn_relay.dart';
import 'services/peer_connection_manager.dart';
import 'services/peer_pairing_service.dart';

/// 客户端把扫到的配对票据交给主机。主机用储物袋的密钥去握手。
class PouchPair {
  PouchPair._();

  static const requestType = 'pouch_pair_req';
  static const responseType = 'pouch_pair_resp';
  static const listRequestType = 'pouch_peer_list_req';
  static const listResponseType = 'pouch_peer_list_resp';

  static const controlTypes = <String>[
    requestType,
    responseType,
    listRequestType,
    listResponseType,
  ];
}

/// 票据就是一条已经校验过的配对链接。主机再解析一次，不信客户端改过的指纹。
class PouchPairTicket {
  PouchPairTicket._();

  static Map<String, dynamic> encode(PeerPairingInfo info) => <String, dynamic>{
        'qr': PeerPairingInfo.encode(
          localEndpoint: info.localEndpoint,
          channelEndpoint: info.channelEndpoint,
          code: info.code,
          fingerprint: info.fingerprint,
          publicKey: info.publicKey,
          name: info.name,
        ),
      };

  static PeerPairingInfo decode(Map<String, dynamic> json) {
    final qr = json['qr'] as String? ?? '';
    final info = PeerPairingInfo.tryParse(qr);
    if (info == null) {
      throw const FormatException('配对票据无效');
    }
    return info;
  }
}

/// 已登录时，扫码配对交给当前这只袋子的主机。App 自己连本机 Hub 不走这里。
class PouchPairing {
  PouchPairing._();

  static Future<PairedPeer> request(
    PeerPairingInfo info, {
    String? correlationId,
  }) async {
    final route = await PouchTurnRelay.currentRoute();
    if (route.runLocal) {
      return PeerPairingService.instance.requestPairing(
        info,
        correlationId: correlationId,
      );
    }
    return PouchPairRelay.instance.forward(
      hostPeerId: route.hostPeerId!,
      info: info,
    );
  }

  /// 界面上的设备名单。客户端读主机的，不读自己扫过的记录。
  static Future<List<PairedPeer>> visiblePeers() async {
    final route = await PouchTurnRelay.currentRoute();
    if (route.runLocal) {
      return PeerConnectionManager.instance.getAllPeers();
    }
    return PouchPairRelay.instance.list(hostPeerId: route.hostPeerId!);
  }
}

class PouchPairRelay {
  PouchPairRelay._();

  static final PouchPairRelay instance = PouchPairRelay._();

  final _uuid = const Uuid();
  final _pending = <String, Completer<Map<String, dynamic>>>{};

  void onResponse(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String? ?? '';
    final pending = _pending.remove(requestId);
    if (pending == null || pending.isCompleted) return;
    pending.complete(data);
  }

  Future<PairedPeer> forward({
    required String hostPeerId,
    required PeerPairingInfo info,
  }) async {
    final done = await _send(hostPeerId, <String, dynamic>{
      'type': PouchPair.requestType,
      ...PouchPairTicket.encode(info),
    });
    if (done['ok'] != true) {
      final code = done['code'] as String? ?? 'error';
      final message = done['message'] as String?;
      if (code == 'rejected') throw PairingRejectedException(message);
      if (code == 'timeout') throw PairingTimeoutException();
      throw StateError(message ?? '主机配对失败');
    }
    final raw = done['peer'];
    if (raw is! Map) throw StateError('主机没有返回配对结果');
    return _peerFromWire(raw.cast<String, dynamic>());
  }

  Future<List<PairedPeer>> list({required String hostPeerId}) async {
    final done = await _send(hostPeerId, <String, dynamic>{
      'type': PouchPair.listRequestType,
    });
    if (done['ok'] != true) {
      throw StateError(done['message'] as String? ?? '读不到主机的设备名单');
    }
    final raw = done['peers'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) _peerFromWire(item.cast<String, dynamic>()),
    ];
  }

  Future<Map<String, dynamic>> _send(
    String hostPeerId,
    Map<String, dynamic> frame,
  ) async {
    final requestId = _uuid.v4();
    final pending = Completer<Map<String, dynamic>>();
    _pending[requestId] = pending;
    frame['request_id'] = requestId;
    final sent = await PeerConnectionManager.instance.sendControl(
      hostPeerId,
      frame,
    );
    if (!sent) {
      _pending.remove(requestId);
      throw StateError('无法把配对交给储物袋主机');
    }
    try {
      return await pending.future.timeout(const Duration(minutes: 6));
    } on TimeoutException {
      _pending.remove(requestId);
      throw PairingTimeoutException();
    }
  }
}

class PouchPairHost {
  PouchPairHost._();

  static Future<void> handle(String peerId, Map<String, dynamic> data) async {
    final requestId = data['request_id'] as String? ?? '';
    final type = data['type'] as String? ?? '';
    Future<void> send(Map<String, dynamic> body) {
      return PeerConnectionManager.instance.sendControl(peerId, {
        'request_id': requestId,
        ...body,
      });
    }

    try {
      final role = await PouchRoleStore(
        await StoreService.instance.storeRoot(),
      ).load();
      if (!role.isHost) {
        await send({
          'type': type == PouchPair.listRequestType
              ? PouchPair.listResponseType
              : PouchPair.responseType,
          'ok': false,
          'code': 'error',
          'message': '这台设备不是储物袋主机',
        });
        return;
      }
      if (type == PouchPair.listRequestType) {
        final peers = await PeerConnectionManager.instance.getAllPeers();
        await send({
          'type': PouchPair.listResponseType,
          'ok': true,
          'peers': [for (final peer in peers) _peerToWire(peer)],
        });
        return;
      }
      final info = PouchPairTicket.decode(data);
      final peer = await PeerPairingService.instance.requestPairing(
        info,
        preferChannel: true,
      );
      await send({
        'type': PouchPair.responseType,
        'ok': true,
        'peer': _peerToWire(peer),
      });
    } on PairingRejectedException catch (e) {
      await send({
        'type': PouchPair.responseType,
        'ok': false,
        'code': 'rejected',
        if (e.reason != null) 'message': e.reason,
      });
    } on PairingTimeoutException {
      await send({
        'type': PouchPair.responseType,
        'ok': false,
        'code': 'timeout',
      });
    } catch (e) {
      await send({
        'type': type == PouchPair.listRequestType
            ? PouchPair.listResponseType
            : PouchPair.responseType,
        'ok': false,
        'code': 'error',
        'message': '$e',
      });
    }
  }
}

Map<String, dynamic> _peerToWire(PairedPeer peer) => <String, dynamic>{
      ...peer.toJson(),
      'state': peer.state.toJson(),
    };

PairedPeer _peerFromWire(Map<String, dynamic> json) {
  final peer = PairedPeer.fromJson(json);
  final state = json['state'] as String?;
  if (state == null) return peer;
  return peer.copyWith(state: PeerConnectionState.fromJson(state));
}

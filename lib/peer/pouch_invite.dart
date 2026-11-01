import '../peer/pouch_pair.dart';
import '../services/logger_service.dart';
import '../storage/pouch_login_client.dart';

/// 已登录的设备签发一个「加入码」：别的设备扫了它，配对之后免密进来。
///
/// 三个帧都走现有的请求-响应通道（和 `PouchPairRelay` 同一条路），所以
/// 必须密封 —— 没登录的设备拿不到 `pouch_invite_resp`。
class PouchInvite {
  const PouchInvite({
    required this.id,
    required this.link,
    required this.expiresAt,
    required this.hostName,
    this.loopback = false,
  });

  final String id;

  /// `shepaw://peer?...&inv=<id>#...`
  final String link;
  final DateTime expiresAt;

  /// 二维码里的 `name`，给加入方认主机用。
  final String hostName;

  /// Hub 只监听回环地址：那台主机现在只能本机连，别的设备扫了也进不来。
  final bool loopback;
}

/// 主机上那条邀请记录的当前状态。
enum PouchInviteState { pending, paired, redeemed, cancelled, expired }

class PouchInviteStatus {
  const PouchInviteStatus({
    required this.state,
    required this.expiresAt,
    this.deviceName,
    this.peerId,
    this.fingerprint,
  });

  final PouchInviteState state;
  final DateTime expiresAt;

  /// 已经配对的那台设备的名字。
  final String? deviceName;
  final String? peerId;
  final String? fingerprint;

  bool get joined =>
      state == PouchInviteState.paired || state == PouchInviteState.redeemed;
}

/// 加入码的三个帧。生产走 [PouchInviteClient.production]，测试注入假的。
class PouchInviteClient {
  const PouchInviteClient({required this.send});

  /// 发一帧、拿回包。和 `PouchPairRelay._send` 同一条路：密封、并且在收到
  /// `pouch_login_required` 时等一次重新登录再重发。
  final Future<Map<String, dynamic>> Function(
    String hostPeerId,
    Map<String, dynamic> body,
  ) send;

  static const createType = 'pouch_invite_req';
  static const createResponseType = 'pouch_invite_resp';
  static const statusType = 'pouch_invite_status_req';
  static const statusResponseType = 'pouch_invite_status_resp';
  static const cancelType = 'pouch_invite_cancel_req';
  static const cancelResponseType = 'pouch_invite_cancel_resp';

  Future<PouchInvite> create({required String hostPeerId}) async {
    final reply = await send(hostPeerId, <String, dynamic>{
      'type': createType,
      'request_id': 'inv-${DateTime.now().microsecondsSinceEpoch}',
    });
    if (reply['ok'] != true) {
      throw StateError((reply['message'] as String?) ?? '没能生成加入码');
    }
    final expiresAtMs = reply['expires_at_ms'];
    return PouchInvite(
      id: (reply['invite_id'] as String?) ?? '',
      link: (reply['link'] as String?) ?? '',
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAtMs is int ? expiresAtMs : 0,
      ),
      hostName: (reply['name'] as String?) ?? '',
      loopback: reply['loopback'] == true,
    );
  }

  Future<PouchInviteStatus> status({
    required String hostPeerId,
    required String inviteId,
  }) async {
    final reply = await send(hostPeerId, <String, dynamic>{
      'type': statusType,
      'request_id': 'invs-${DateTime.now().microsecondsSinceEpoch}',
      'invite_id': inviteId,
    });
    final expiresAtMs = reply['expires_at_ms'];
    return PouchInviteStatus(
      state: _stateOf(reply['state'] as String?),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAtMs is int ? expiresAtMs : 0,
      ),
      deviceName: reply['device_name'] as String?,
      peerId: reply['peer_id'] as String?,
      fingerprint: reply['fingerprint'] as String?,
    );
  }

  Future<void> cancel({
    required String hostPeerId,
    required String inviteId,
  }) async {
    await send(hostPeerId, <String, dynamic>{
      'type': cancelType,
      'request_id': 'invc-${DateTime.now().microsecondsSinceEpoch}',
      'invite_id': inviteId,
    });
  }
}

PouchInviteState _stateOf(String? raw) {
  return switch (raw) {
    'pending' => PouchInviteState.pending,
    'paired' => PouchInviteState.paired,
    'redeemed' => PouchInviteState.redeemed,
    'cancelled' => PouchInviteState.cancelled,
    _ => PouchInviteState.expired,
  };
}

/// 接真实通道的那份。
PouchInviteClient productionInviteClient() {
  return PouchInviteClient(
    send: (hostPeerId, body) async {
      final reply = await PouchPairRelay.instance.raw(hostPeerId, body);
      LoggerService().info('invite ${body['type']} -> $reply', tag: 'Invite');
      return reply;
    },
  );
}

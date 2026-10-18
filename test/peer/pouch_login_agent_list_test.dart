import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/storage/pouch_login.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // _greetHost 会顺手发 device.hello，它要读设备 id；没有插件时这个平台
  // 调用可能一直悬着，挂住整条测试套件的收尾。
  SharedPreferences.setMockInitialValues({});

  final svc = PeerAgentClientService.instance;

  PouchSession session(String hostPeerId) {
    return PouchSession(
      hubUrl: 'ws://127.0.0.1:1/peer/ws',
      pouchId: 'pouch-a',
      pouchName: '书房',
      hostPeerId: hostPeerId,
      token: 'login-token',
      sessionId: 'sid-1',
      expiresAtMs: DateTime.now().millisecondsSinceEpoch + 60000,
    );
  }

  tearDown(() {
    svc.debugResetPeerMetaForTest();
    PouchChannel.clear();
  });

  test('登录回包先到时不拉名单，通道装上并且已连接才拉', () async {
    final sent = <String>[];
    svc.debugTreatAsRunning = true;
    svc.debugConnectedPeerIdsOverride = {'host-1'};
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json['type'] as String? ?? '');
      return true;
    };

    svc.debugInjectControlForTest(
      'pouch_login_resp',
      {'accepted': true},
      peerId: 'host-1',
    );
    await Future<void>.delayed(Duration.zero);
    expect(sent, isNot(contains('agent_list_req')));

    PouchChannel.install(session('host-1'));
    await Future<void>.delayed(Duration.zero);
    expect(
      sent.where((type) =>
          type == 'agent_list_req' || type == 'agent_pending_interactions_req'),
      ['agent_list_req', 'agent_pending_interactions_req'],
    );
  });

  // 建连时主机自己补发的那一次可能早于登录/订阅控制流；登录完成后的
  // 主动查询才是兜底。重连同样要重问，否则重连前错过的卡永远回不来。
  test('登录后重连会再问一次没答的卡片', () async {
    final sent = <String>[];
    svc.debugTreatAsRunning = true;
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json['type'] as String? ?? '');
      return true;
    };
    PouchChannel.install(session('host-1'));

    svc.debugInjectConnectionEvent(PeerConnectionEvent(
      peerId: 'host-1',
      type: PeerConnectionEventType.connected,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(
      sent.where((type) => type == 'agent_pending_interactions_req'),
      ['agent_pending_interactions_req'],
    );
  });

  test('通道装上但主机还没连上时不拉名单', () async {
    final sent = <String>[];
    svc.debugTreatAsRunning = true;
    svc.debugConnectedPeerIdsOverride = <String>{};
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json['type'] as String? ?? '');
      return true;
    };

    PouchChannel.install(session('host-1'));
    await Future<void>.delayed(Duration.zero);
    expect(sent, isNot(contains('agent_list_req')));
    expect(sent, isNot(contains('agent_pending_interactions_req')));
  });
}

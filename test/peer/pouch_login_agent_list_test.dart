import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/storage/pouch_login.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    expect(sent.where((type) => type == 'agent_list_req'), ['agent_list_req']);
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
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/card_status.dart';
import 'package:shepaw/peer/peer_approval_payload.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

import '../storage/test_harness.dart';

/// 卡片有效性查询与提交回执：这两条是「打开会话查一次 / 15 秒复查」
/// 以及「主机拒收时不标已答」的协议底座。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(StorageTestHarness.init);

  final svc = PeerAgentClientService.instance;

  tearDown(() {
    svc.debugSendControlOverride = null;
    svc.debugExpectCardAck = false;
    svc.debugExpectCardStatus = false;
    svc.debugCardStatusTimeout = const Duration(seconds: 5);
  });

  Map<String, dynamic> formFrame(String requestId, String approvalId) => {
        'request_id': requestId,
        'approval_id': approvalId,
        'agent_id': 'remote-agent',
        'channel_id': 'dm_remote-agent_user_1',
        'title': '选一个',
        'fields': [
          {
            'field_id': 'question_0',
            'type': 'text_input',
            'label': '选哪个',
          }
        ],
      };

  test('按 request_id 收状态回包，alive / 跨端回答 / gone 都能区分', () async {
    svc.debugExpectCardStatus = true;
    final sent = <Map<String, dynamic>>[];
    svc.debugSendControlOverride = (peerId, json) async {
      sent.add(json);
      if (json['type'] == 'agent_card_status_req') {
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              {'id': 'c-alive', 'state': 'alive'},
              {'id': 'c-answered', 'state': 'answered_elsewhere'},
              {'id': 'c-gone', 'state': 'gone'},
              {'id': 'ix-1', 'state': 'answered_elsewhere'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    final entries = await svc.checkCardStatus(
      peerId: 'peer-1',
      channelId: 'dm_remote-agent_user_1',
      cardIds: const ['c-alive', 'c-answered', 'c-gone'],
      interactionIds: const ['ix-1'],
    );

    expect(sent, hasLength(1));
    expect(sent.single['type'], 'agent_card_status_req');
    expect(sent.single['channel_id'], 'dm_remote-agent_user_1');
    expect(sent.single['card_ids'], ['c-alive', 'c-answered', 'c-gone']);
    expect(entries, hasLength(4));
    expect(entries[0].isAlive, isTrue);
    expect(entries[1].isAnsweredElsewhere, isTrue);
    expect(entries[2].isGone, isTrue);
    expect(entries[3].isAnsweredElsewhere, isTrue);
  });

  test('没有回包时返回空列表（不能因为网络抖动删卡片）', () async {
    svc.debugExpectCardStatus = true;
    svc.debugCardStatusTimeout = const Duration(milliseconds: 30);
    svc.debugSendControlOverride = (_, __) async => true;
    final entries = await svc.checkCardStatus(
      peerId: 'peer-1',
      channelId: 'dm_remote-agent_user_1',
      cardIds: const ['c-1'],
    );
    expect(entries, isEmpty);
  });

  test('主机回 ok=false 时 submitForm 抛错，卡片不会被标成已答', () async {    final turn = svc.debugSeedPendingTurn(
      requestId: 'req-card-ack',
      peerId: 'peer-1',
      channelId: 'ch-card-ack',
    );
    turn.then((_) {}, onError: (_) {});
    addTearDown(() => svc.cancelInflightTurnsForChannel('ch-card-ack'));

    svc.debugInjectControlForTest(
      'agent_form_req',
      formFrame('req-card-ack', 'ack-rejected'),
      peerId: 'peer-1',
    );
    await pumpEventQueue();

    svc.debugExpectCardAck = true;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_form_resp') {
        expect(json['channel_id'], isNotNull);
        svc.debugInjectControlForTest(
          'agent_card_resp_ack',
          {
            'type': 'agent_card_resp_ack',
            'approval_id': json['approval_id'],
            'ok': false,
            'reason': 'session_mismatch',
          },
          peerId: peerId,
        );
      }
      return true;
    };

    await expectLater(
      svc.submitForm(
        peerId: 'peer-1',
        approvalId: 'ack-rejected',
        values: const {'question_0': '选 A'},
        hostChannelId: 'dm_remote-agent_user_1',
      ),
      throwsA(isA<PeerCardRejectedException>()),
    );
  });

  test('终态拒收按「已失效」处理，不会被通用回滚复活', () {
    expect(
      PeerApprovalExpiredException.matches(
        const PeerCardRejectedException('expired'),
      ),
      isTrue,
    );
    expect(
      PeerApprovalExpiredException.matches(
        const PeerCardRejectedException('answered_elsewhere'),
      ),
      isTrue,
    );
    // 跨会话 / 答案没送达到不是终态：卡还活着，应该能回滚重试。
    expect(
      PeerApprovalExpiredException.matches(
        const PeerCardRejectedException('session_mismatch'),
      ),
      isFalse,
    );
    expect(
      PeerApprovalExpiredException.matches(
        const PeerCardRejectedException('answer_pending'),
      ),
      isFalse,
    );
  });

  test('同一张卡并发提交时两个等待位都收到回执，不会互相清掉', () async {
    final turn = svc.debugSeedPendingTurn(
      requestId: 'req-card-ack-double',
      peerId: 'peer-1',
      channelId: 'ch-card-ack-double',
    );
    turn.then((_) {}, onError: (_) {});
    addTearDown(() => svc.cancelInflightTurnsForChannel('ch-card-ack-double'));

    svc.debugInjectControlForTest(
      'agent_form_req',
      formFrame('req-card-ack-double', 'ack-double'),
      peerId: 'peer-1',
    );
    await pumpEventQueue();

    svc.debugExpectCardAck = true;
    var responses = 0;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_form_resp') {
        responses++;
        if (responses == 1) {
          svc.debugInjectControlForTest(
            'agent_card_resp_ack',
            {
              'type': 'agent_card_resp_ack',
              'approval_id': json['approval_id'],
              'ok': false,
              'reason': 'expired',
            },
            peerId: peerId,
          );
        }
      }
      return true;
    };

    // 两次提交都登记了等待位；第一个回执到达时两张都该被拒，不能有一个
    // 因为等待位被覆盖而误判「老主机无 ack」把卡片标成已答。
    final first = svc.submitForm(
      peerId: 'peer-1',
      approvalId: 'ack-double',
      values: const {'question_0': '选 A'},
      hostChannelId: 'dm_remote-agent_user_1',
    );
    final second = svc.submitForm(
      peerId: 'peer-1',
      approvalId: 'ack-double',
      values: const {'question_0': '选 B'},
      hostChannelId: 'dm_remote-agent_user_1',
    );
    await expectLater(first, throwsA(isA<PeerCardRejectedException>()));
    await expectLater(second, throwsA(isA<PeerCardRejectedException>()));
  });
}

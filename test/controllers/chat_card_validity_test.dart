import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

import '../storage/test_harness.dart';

/// 打开会话立刻检测、有效卡 15 秒复查、失效卡移除、被别的端回答则保留并
/// 标记 + 提示、离开会话停止轮询。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(StorageTestHarness.init);

  final svc = PeerAgentClientService.instance;

  Message card(
    String id, {
    required String cardId,
    required String key,
    String? cardChannelId,
  }) =>
      Message(
        id: id,
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
        type: MessageType.text,
        content: '选一个',
        timestampMs: 0,
        metadata: {
          key: {
            'form_id': cardId,
            'confirmation_id': cardId,
            'peer_form': {
              'peer_id': 'peer-1',
              'approval_id': cardId,
            },
          },
          if (cardChannelId != null) 'card_channel_id': cardChannelId,
        },
      );

  late ChatController controller;

  setUp(() {
    controller = ChatController(
      agentId: 'remote-agent',
      initialAgentName: 'Remote',
      initialChannelId: 'dm_remote-agent_user_1',
      getUserId: () => 'user-1',
      getUserName: () => 'User',
    );
    controller.currentChannelId = 'dm_remote-agent_user_1';
    svc.debugExpectCardStatus = true;
  });

  tearDown(() {
    controller.dispose();
    svc.debugSendControlOverride = null;
    svc.debugExpectCardStatus = false;
  });

  test('失效卡移除、跨端回答的卡保留并标记、有效卡不动', () async {
    final events = <ChatEvent>[];
    final sub = controller.events.listen(events.add);
    addTearDown(sub.cancel);
    controller.messages.addAll([
      card('row-gone', cardId: 'c-gone', key: 'form'),
      card('row-answered', cardId: 'c-answered', key: 'form'),
      card('row-alive', cardId: 'c-alive', key: 'form'),
    ]);
    controller.rebuildMessageIdMap();

    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        expect(json['channel_id'], 'dm_remote-agent_user_1');
        expect(json['card_ids'], containsAll(['c-gone', 'c-answered', 'c-alive']));
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              {'id': 'c-gone', 'state': 'gone'},
              {'id': 'c-answered', 'state': 'answered_elsewhere'},
              {'id': 'c-alive', 'state': 'alive'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    await controller.checkCardValidity();
    await pumpEventQueue();

    expect(controller.messages.any((m) => m.id == 'row-gone'), isFalse,
        reason: '主机确认失效的卡要直接移除');
    final answered = controller.messages.firstWhere((m) => m.id == 'row-answered');
    final form = answered.metadata?['form'] as Map;
    expect(form['closed'], 'answered_elsewhere');
    expect(form['submitted_values'], isNull);
    final alive = controller.messages.firstWhere((m) => m.id == 'row-alive');
    expect((alive.metadata?['form'] as Map)['closed'], isNull);
    expect(events.whereType<ShowSnackBarEvent>(), hasLength(1),
        reason: '被其他端回答要给提示');
  });

  test('打开会话立即查一次，之后按 15 秒节奏复查；无卡时不发请求', () async {
    controller.messages.add(card('row-alive', cardId: 'c-alive', key: 'form'));
    controller.rebuildMessageIdMap();
    var requests = 0;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        requests++;
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              // 第一次还有效，下一次复查时已被别的端答掉。
              {'id': 'c-alive', 'state': requests == 1 ? 'alive' : 'gone'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    controller.startCardValidityWatch();
    await pumpEventQueue();
    expect(requests, 1, reason: '打开会话立即检测一次');
    expect(controller.cardValidityPolling, isTrue,
        reason: '还有有效卡时保持 15 秒轮询');

    await controller.checkCardValidity();
    expect(requests, 2);
    expect(controller.messages, isEmpty, reason: '这次主机说已失效 → 移除卡片');
    expect(controller.cardValidityPolling, isTrue,
        reason: '定时器跟着会话走，期间新到达的卡下一轮仍会被检测');

    // 卡片收完后不再发空请求。
    await controller.checkCardValidity();
    expect(requests, 2);
  });

  test('hub 交互卡只按 interaction_id 对账，不会被误当 approval_id', () async {
    controller.messages.add(
      Message(
        id: 'row-hub',
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
        type: MessageType.text,
        content: '选一个',
        timestampMs: 0,
        metadata: {
          'hub_interaction': {
            'host_peer_id': 'peer-1',
            'interaction_id': 'ix-1',
          },
          // hub 卡同时带一份 form 载荷；不能再把它塞进 card_ids。
          'form': {
            'form_id': 'ix-1',
            'peer_form': {'peer_id': 'peer-1', 'approval_id': 'ix-1'},
          },
        },
      ),
    );
    controller.rebuildMessageIdMap();

    Map<String, dynamic>? sent;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        sent = json;
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              {'id': 'ix-1', 'state': 'alive'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    await controller.checkCardValidity();
    expect(sent, isNotNull);
    expect(sent!['card_ids'], isEmpty);
    expect(sent!['interaction_ids'], ['ix-1']);
    expect(controller.messages, hasLength(1), reason: 'alive 的 hub 卡保留');
  });

  test('离开当前会话时显式停止轮询', () async {
    controller.messages.add(card('row-alive', cardId: 'c-live', key: 'form'));
    controller.rebuildMessageIdMap();
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              {'id': 'c-live', 'state': 'alive'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };
    controller.startCardValidityWatch();
    await pumpEventQueue();
    expect(controller.cardValidityPolling, isTrue);
    // switchChannel / dispose 走的都是这个入口。
    controller.stopCardValidityWatch();
    expect(controller.cardValidityPolling, isFalse);
  });
}

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
  var disposedInTest = false;

  setUp(() {
    disposedInTest = false;
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
    if (!disposedInTest) controller.dispose();
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

  test('dispose 之后在途的状态回包不再改写已销毁的 controller', () async {
    controller.messages
        .add(card('row-late', cardId: 'c-late', key: 'form'));
    controller.rebuildMessageIdMap();
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        // 回包晚于 dispose 到达。
        Future<void>.delayed(const Duration(milliseconds: 30), () {
          svc.debugInjectControlForTest(
            'agent_card_status_resp',
            {
              'type': 'agent_card_status_resp',
              'request_id': json['request_id'],
              'channel_id': json['channel_id'],
              'cards': [
                {'id': 'c-late', 'state': 'gone'},
              ],
            },
            peerId: peerId,
          );
        });
      }
      return true;
    };

    final pending = controller.checkCardValidity();
    disposedInTest = true;
    controller.dispose();
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(controller.messages, hasLength(1),
        reason: 'dispose 后不能删行 / _notify 已销毁的 controller');
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

  test('本地工具卡不参与对账，不会被主机回的 gone 误删', () async {
    // She / 群编排用同一个 form / action_confirmation 键画卡，但主机没有
    // 它们的等待位，一律回 gone。只有带 peer_form / card_channel_id 的
    // 主机卡才能进 agent_card_status_req。
    controller.messages.addAll([
      Message(
        id: 'row-local-form',
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
        type: MessageType.text,
        content: '本地表单',
        timestampMs: 0,
        metadata: {
          'form': {'form_id': 'local-form-1', 'fields': []},
        },
      ),
      Message(
        id: 'row-local-approval',
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
        type: MessageType.text,
        content: '本地审批',
        timestampMs: 0,
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'local-approval-1',
            'confirmation_context': 'peer',
            'actions': [
              {'id': 'allow', 'label': '允许'}
            ],
          },
        },
      ),
    ]);
    controller.rebuildMessageIdMap();

    var requests = 0;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') requests++;
      return true;
    };

    await controller.checkCardValidity();
    expect(requests, 0, reason: '本地卡没有主机等待位，不该发状态查询');
    expect(controller.messages, hasLength(2), reason: '本地卡必须留在屏幕上');
  });

  test('归属别的会话的残留卡不参与本次对账', () async {
    controller.messages.addAll([
      // B 会话残留的卡：若拿 A 的 channel 去问，主机回 gone 会把 B 唯一
      // 一份落库副本删掉。
      card('row-foreign',
          cardId: 'c-foreign', key: 'form', cardChannelId: 'dm_other_session'),
      card('row-mine', cardId: 'c-mine', key: 'form'),
    ]);
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
              {'id': 'c-mine', 'state': 'alive'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    await controller.checkCardValidity();
    expect(sent, isNotNull);
    expect(sent!['card_ids'], ['c-mine']);
    expect(controller.messages.map((m) => m.id),
        containsAll(['row-foreign', 'row-mine']));
  });

  test('不同主机的卡分别问各自的主机，不合并到一个请求', () async {
    controller.messages.addAll([
      card('row-a', cardId: 'c-a', key: 'form'),
      Message(
        id: 'row-b',
        from: MessageFrom(id: 'agent-2', type: 'agent', name: 'Other'),
        type: MessageType.text,
        content: '选一个',
        timestampMs: 0,
        metadata: {
          'form': {
            'form_id': 'c-b',
            'peer_form': {
              'peer_id': 'peer-2',
              'approval_id': 'c-b',
            },
          },
          'card_channel_id': 'dm_remote-agent_user_1',
        },
      ),
      Message(
        id: 'row-hub',
        from: MessageFrom(id: 'agent-2', type: 'agent', name: 'Other'),
        type: MessageType.text,
        content: '选一个',
        timestampMs: 0,
        metadata: {
          'hub_interaction': {
            'host_peer_id': 'peer-3',
            'interaction_id': 'ix-3',
          },
        },
      ),
    ]);
    controller.rebuildMessageIdMap();

    final byPeer = <String, Map<String, dynamic>>{};
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req') {
        byPeer[peerId] = Map<String, dynamic>.from(json);
        final ids = <String>[
          ...(json['card_ids'] as List).cast<String>(),
          ...(json['interaction_ids'] as List).cast<String>(),
        ];
        svc.debugInjectControlForTest(
          'agent_card_status_resp',
          {
            'type': 'agent_card_status_resp',
            'request_id': json['request_id'],
            'channel_id': json['channel_id'],
            'cards': [
              for (final id in ids) {'id': id, 'state': 'alive'},
            ],
          },
          peerId: peerId,
        );
      }
      return true;
    };

    await controller.checkCardValidity();
    expect(byPeer.keys, unorderedEquals(['peer-1', 'peer-2', 'peer-3']));
    expect(byPeer['peer-1']!['card_ids'], ['c-a']);
    expect(byPeer['peer-2']!['card_ids'], ['c-b']);
    expect(byPeer['peer-3']!['interaction_ids'], ['ix-3']);
    expect(controller.messages, hasLength(3));
  });

  test('重复 loadMessages 不会重建 15 秒定时器', () async {
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
    final timer = controller.cardValidityTimerForTest;
    // 一轮对话里 loadMessages 会被反复调用，startCardValidityWatch 跟着跑。
    controller.startCardValidityWatch();
    controller.startCardValidityWatch();
    expect(identical(timer, controller.cardValidityTimerForTest), isTrue,
        reason: '倒计时不能被每次 loadMessages 清零');
    expect(controller.cardValidityPolling, isTrue);
  });

  test('切频道后在途回包不改写新会话，也不挡住新会话立即查', () async {
    controller.messages.add(card('row-late', cardId: 'c-late', key: 'form'));
    controller.rebuildMessageIdMap();
    var injected = false;
    svc.debugSendControlOverride = (peerId, json) async {
      if (json['type'] == 'agent_card_status_req' && !injected) {
        injected = true;
        // 回包晚于切频道到达，且把旧卡判成 gone。
        Future<void>.delayed(const Duration(milliseconds: 30), () {
          svc.debugInjectControlForTest(
            'agent_card_status_resp',
            {
              'type': 'agent_card_status_resp',
              'request_id': json['request_id'],
              'channel_id': json['channel_id'],
              'cards': [
                {'id': 'c-late', 'state': 'gone'},
              ],
            },
            peerId: peerId,
          );
        });
      }
      return true;
    };

    final pending = controller.checkCardValidity();
    controller.stopCardValidityWatch();
    controller.currentChannelId = 'dm_other_session';
    await pending;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();

    expect(controller.messages, hasLength(1),
        reason: '旧会话的 gone 不能删掉新会话列表里的行');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/controllers/chat_streaming_text.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection_manager.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

/// hub 交互卡（`interaction.pending`）的提交是「发送即乐观落库」。本轮补的
/// 两道防线：① 卡帧归属与当前会话不符时提交前就拦下；② 主机回
/// `agent_card_resp_ack(ok=false)` 时撤回乐观写入，避免错误会话一直显示
/// 已提交（hub-ix-<id> 是全局确定性行，正确会话重载后也会点不动）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await StorageTestHarness.init();
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    await LocalDatabaseService().database;
  });

  final svc = PeerAgentClientService.instance;
  const channelId = 'dm_hub_rejection_user_1';

  Message hubCard({
    required String interactionId,
    required String cardChannelId,
    String? selectedActionId,
  }) =>
      Message(
        id: 'hub-ix-$interactionId',
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Claude'),
        type: MessageType.text,
        content: '要允许吗',
        timestampMs: 0,
        metadata: {
          'hub_interaction': {
            'host_peer_id': 'peer-1',
            'interaction_id': interactionId,
            'interaction_type': 'action_confirmation',
          },
          'card_channel_id': cardChannelId,
          'action_confirmation': {
            'confirmation_id': interactionId,
            'confirmation_context': 'peer',
            'prompt': '要允许吗',
            'actions': [
              {'id': 'allow', 'label': '允许'}
            ],
            if (selectedActionId != null)
              'selected_action_id': selectedActionId,
          },
        },
      );

  late ChatController controller;
  late List<ChatEvent> events;

  setUp(() {
    controller = ChatController(
      agentId: 'agent-1',
      initialAgentName: 'Agent',
      initialChannelId: channelId,
      getUserId: () => 'user-1',
      getUserName: () => 'User',
    );
    controller.currentChannelId = channelId;
    controller.installOrphanCardListenersForTest();
    events = <ChatEvent>[];
    addTearDown(controller.events.listen(events.add).cancel);
  });

  tearDown(() {
    controller.dispose();
    svc.debugSendControlOverride = null;
    svc.debugExpectCardAck = false;
    PeerConnectionManager.instance.debugTrySendControlOverride = null;
  });

  test('归属别的会话的 hub 卡在提交前被拦下，不发帧也不乐观落库', () async {
    final message = hubCard(
      interactionId: 'ix-foreign',
      cardChannelId: 'dm_other_session',
    );
    controller.messages.add(message);
    controller.rebuildMessageIdMap();

    final sent = <Map<String, dynamic>>[];
    PeerConnectionManager.instance.debugTrySendControlOverride =
        (peerId, json) async {
      sent.add(json);
      return true;
    };
    addTearDown(() =>
        PeerConnectionManager.instance.debugTrySendControlOverride = null);

    await controller.handleActionSelected(
      message,
      'ix-foreign',
      'allow',
      '允许',
      confirmationContext: 'peer',
    );
    await pumpEventQueue();

    expect(sent, isEmpty, reason: '跨会话的卡不该发出 pouch_interaction_resp');
    expect(
      events.whereType<ShowErrorSnackBarEvent>(),
      hasLength(1),
      reason: '要给用户明确提示',
    );
    final ac = controller.messages.single.metadata?['action_confirmation']
        as Map;
    expect(ac['selected_action_id'], isNull,
        reason: '被拦下时不能把卡标成已答');
  });

  test('归属本会话的 hub 卡照常提交', () async {
    final message = hubCard(
      interactionId: 'ix-own',
      cardChannelId: channelId,
    );
    controller.messages.add(message);
    controller.rebuildMessageIdMap();

    final sent = <Map<String, dynamic>>[];
    PeerConnectionManager.instance.debugTrySendControlOverride =
        (peerId, json) async {
      sent.add(json);
      return true;
    };
    addTearDown(() =>
        PeerConnectionManager.instance.debugTrySendControlOverride = null);

    await controller.handleActionSelected(
      message,
      'ix-own',
      'allow',
      '允许',
      confirmationContext: 'peer',
    );
    await pumpEventQueue();

    expect(sent, hasLength(1));
    expect(sent.single['type'], 'pouch_interaction_resp');
    expect(sent.single['channel_id'], channelId);
    final ac = controller.messages.single.metadata?['action_confirmation']
        as Map;
    expect(ac['selected_action_id'], 'allow');
  });

  test('主机回 session_mismatch 时撤回乐观写入并提示', () async {
    final message = hubCard(
      interactionId: 'ix-rejected',
      cardChannelId: channelId,
      selectedActionId: 'allow',
    );
    controller.messages.add(message);
    controller.rebuildMessageIdMap();

    svc.debugInjectControlForTest(
      'agent_card_resp_ack',
      {
        'type': 'agent_card_resp_ack',
        'approval_id': 'ix-rejected',
        'ok': false,
        'reason': 'session_mismatch',
      },
      peerId: 'peer-1',
    );
    await pumpEventQueue();

    final ac = controller.messages.single.metadata?['action_confirmation']
        as Map;
    expect(ac['selected_action_id'], isNull,
        reason: '主机拒收后卡片要恢复可答');
    expect(
      events.whereType<ShowErrorSnackBarEvent>(),
      hasLength(1),
      reason: '用户要知道答案没被收下',
    );
  });

  test('已作废（closed）的 hub 卡不会被拒绝回执错误恢复成可答', () async {
    final message = hubCard(
      interactionId: 'ix-closed',
      cardChannelId: channelId,
    );
    final meta = Map<String, dynamic>.from(message.metadata!);
    meta['action_confirmation'] = {
      ...(meta['action_confirmation'] as Map),
      'closed': 'timeout',
    };
    final closed = ChatStreamingText.withMergedMetadata(message, meta);
    controller.messages.add(closed);
    controller.rebuildMessageIdMap();

    svc.debugInjectControlForTest(
      'agent_card_resp_ack',
      {
        'type': 'agent_card_resp_ack',
        'approval_id': 'ix-closed',
        'ok': false,
        'reason': 'session_mismatch',
      },
      peerId: 'peer-1',
    );
    await pumpEventQueue();

    final ac = controller.messages.single.metadata?['action_confirmation']
        as Map;
    expect(ac['closed'], 'timeout', reason: '作废态不能被回滚掉');
    expect(events.whereType<ShowErrorSnackBarEvent>(), isEmpty,
        reason: '没有回滚就不该重复弹提示');
  });
}

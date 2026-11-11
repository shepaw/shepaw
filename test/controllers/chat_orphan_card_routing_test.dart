import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/services/approval/pending_approval_hub.dart';

import '../storage/test_harness.dart';

/// 单聊的审核卡曾经会被任何打开着的群聊认领：卡帧没有会话归属，群分支
/// 只按 `groupAgents` 匹配成员。主机现在在帧里带 `channel_id`，这里从
/// Controller 入口锁住「不是本群的卡不碰 messages」。
///
/// 不跑 `init()`（会拉本地库和历史）；只装孤儿卡监听，直接注入控制帧。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const remoteAgentId = 'remote-agent';
  const peerId = 'peer-orphan-routing';
  const adminAgentId = 'admin-agent';

  var seq = 0;
  String nextApprovalId() => 'appr-routing-${seq++}';
  // 每个用例一条新频道：孤儿卡缓存是进程级的，固定 id 会让上一个用例的卡
  // 在下一个用例的补投里冒出来。
  String nextGroupChannelId() => 'group_orphan_routing_${seq++}';
  String nextDmChannelId() => 'dm_remote-agent_user_${seq++}';

  RemoteAgent peerAgent() {
    const now = 1;
    return RemoteAgent(
      id: remoteAgentId,
      name: 'Remote',
      avatar: '🤖',
      token: 't',
      endpoint: '',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.http,
      status: AgentStatus.online,
      metadata: {
        'source_peer_id': peerId,
        'remote_agent_id': remoteAgentId,
      },
      createdAt: now,
      updatedAt: now,
    );
  }

  Map<String, dynamic> approvalFrame({
    required String approvalId,
    required String requestId,
    String? channelId = 'dm_remote-agent_user_1',
  }) =>
      {
        'request_id': requestId,
        'approval_id': approvalId,
        'agent_id': remoteAgentId,
        if (channelId != null) 'channel_id': channelId,
        'prompt': 'run ls',
        'actions': [
          {'id': 'allow', 'label': 'Allow', 'style': 'primary'},
          {'id': 'deny', 'label': 'Deny', 'style': 'danger'},
        ],
        'tool_kind': 'execute',
        'tool_call_id': 't1',
      };

  late ChatController controller;
  late String groupChannelId;

  // 补投（_drainPendingOrphanCards）要查本地库解析 agent，走 path_provider。
  setUpAll(StorageTestHarness.init);

  setUp(() {
    PendingApprovalHub.instance.resetForTest();
    groupChannelId = nextGroupChannelId();
    controller = ChatController(
      agentId: adminAgentId,
      initialAgentName: 'Admin',
      initialChannelId: groupChannelId,
      getUserId: () => 'user-1',
      getUserName: () => 'User',
    );
    // loadMessages 才会从库里解析这两项；这里直接给出群场景。
    controller.currentChannelId = groupChannelId;
    controller.isGroupMode = true;
    controller.groupAgents = [peerAgent()];
    controller.installOrphanCardListenersForTest();
  });

  tearDown(() {
    controller.dispose();
    PendingApprovalHub.instance.resetForTest();
  });

  test('单聊的卡不会被群聊认领', () async {
    final approvalId = nextApprovalId();
    PeerAgentClientService.instance.debugInjectControlForTest(
      'agent_approval_req',
      approvalFrame(
        approvalId: approvalId,
        requestId: 'req-$approvalId',
        channelId: 'dm_remote-agent_user_1',
      ),
      peerId: peerId,
    );
    await pumpEventQueue();

    expect(
      controller.messages,
      isEmpty,
      reason: '卡的归属不是本群，不能写进群消息列表',
    );
    expect(PendingApprovalHub.instance.countForChannel(groupChannelId), 0);
  });

  test('没有会话归属的卡同样不认领', () async {
    final approvalId = nextApprovalId();
    PeerAgentClientService.instance.debugInjectControlForTest(
      'agent_approval_req',
      approvalFrame(
        approvalId: approvalId,
        requestId: 'req-$approvalId',
        channelId: null,
      ),
      peerId: peerId,
    );
    await pumpEventQueue();

    expect(controller.messages, isEmpty);
    expect(PendingApprovalHub.instance.countForChannel(groupChannelId), 0);
  });

  test('归属本群的卡照常渲染（监听确实装上了）', () async {
    final approvalId = nextApprovalId();
    PeerAgentClientService.instance.debugInjectControlForTest(
      'agent_approval_req',
      approvalFrame(
        approvalId: approvalId,
        requestId: 'req-$approvalId',
        channelId: groupChannelId,
      ),
      peerId: peerId,
    );
    await pumpEventQueue();

    expect(
      controller.messages,
      isNotEmpty,
      reason: '群成员发起的卡应该走群 fallback 气泡',
    );
    expect(PendingApprovalHub.instance.countForChannel(groupChannelId), 1);
  });

  group('DM 按会话认领', () {
    late ChatController dm;
    late String dmChannelId;

    setUp(() {
      dmChannelId = nextDmChannelId();
      dm = ChatController(
        agentId: remoteAgentId,
        initialAgentName: 'Remote',
        initialChannelId: dmChannelId,
        getUserId: () => 'user-1',
        getUserName: () => 'User',
      );
      dm.currentChannelId = dmChannelId;
      dm.installOrphanCardListenersForTest();
    });

    tearDown(() => dm.dispose());

    test('别的会话的卡不落进当前单聊', () async {
      final approvalId = nextApprovalId();
      PeerAgentClientService.instance.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(
          approvalId: approvalId,
          requestId: 'req-$approvalId',
          channelId: nextDmChannelId(),
        ),
        peerId: peerId,
      );
      await pumpEventQueue();

      expect(dm.messages, isEmpty);
    });

    test('本会话的卡照常渲染', () async {
      final approvalId = nextApprovalId();
      PeerAgentClientService.instance.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(
          approvalId: approvalId,
          requestId: 'req-$approvalId',
          channelId: dmChannelId,
        ),
        peerId: peerId,
      );
      await pumpEventQueue();

      expect(dm.messages, isNotEmpty);
    });

    ChatController anotherDm(String channelId) {
      final other = ChatController(
        agentId: remoteAgentId,
        initialAgentName: 'Remote',
        initialChannelId: channelId,
        getUserId: () => 'user-1',
        getUserName: () => 'User',
      );
      other.currentChannelId = channelId;
      other.installOrphanCardListenersForTest();
      addTearDown(other.dispose);
      return other;
    }

    test('两个同时打开的单聊都不认领无归属卡', () async {
      final other = anotherDm(nextDmChannelId());
      final approvalId = nextApprovalId();
      PeerAgentClientService.instance.debugInjectControlForTest(
        'agent_approval_req',
        approvalFrame(
          approvalId: approvalId,
          requestId: 'req-$approvalId',
          channelId: null,
        ),
        peerId: peerId,
      );
      await pumpEventQueue();

      expect(dm.messages, isEmpty,
          reason: '旧实现会让任何打开的 DM 认领，两个会话会各挂一张');
      expect(other.messages, isEmpty);
    });

    test('多会话并发时表单卡只进归属的那个会话', () async {
      final otherChannelId = nextDmChannelId();
      final other = anotherDm(otherChannelId);
      final approvalId = nextApprovalId();
      PeerAgentClientService.instance.debugInjectControlForTest(
        'agent_form_req',
        {
          'request_id': 'req-$approvalId',
          'approval_id': approvalId,
          'agent_id': remoteAgentId,
          'channel_id': otherChannelId,
          'title': '选一个',
          'fields': [
            {
              'field_id': 'question_0',
              'type': 'text_input',
              'label': '选哪个',
            }
          ],
        },
        peerId: peerId,
      );
      await pumpEventQueue();

      expect(dm.messages, isEmpty, reason: 'A 会话不该出现 B 会话的提问卡');
      expect(other.messages, isNotEmpty,
          reason: '归属 B 的卡必须在 B 里还能看到（证明监听确实装上）');
    });
  });

  group('跨会话提交', () {
    test('A 会话里的 B 会话卡片不能直接提交', () async {
      final controller = ChatController(
        agentId: remoteAgentId,
        initialAgentName: 'Remote',
        initialChannelId: 'dm_remote-agent_user_a',
        getUserId: () => 'user-1',
        getUserName: () => 'User',
      )..currentChannelId = 'dm_remote-agent_user_a';
      addTearDown(controller.dispose);
      final events = <ChatEvent>[];
      final sub = controller.events.listen(events.add);
      addTearDown(sub.cancel);

      final message = Message(
        id: 'peer_form_cross-session',
        from: MessageFrom(
            id: 'remote-agent', type: 'agent', name: 'Remote'),
        type: MessageType.text,
        content: '选一个',
        timestampMs: 0,
        metadata: {
          'card_channel_id': 'dm_remote-agent_user_b',
          'form': {
            'form_id': 'cross-session',
            'peer_form': {
              'peer_id': peerId,
              'approval_id': 'cross-session',
            },
          },
        },
      );
      await controller.handleFormSubmitted(
        message,
        'cross-session',
        {'question_0': '选 A'},
        '选 A',
      );
      await pumpEventQueue();

      expect(
        events.whereType<ShowErrorSnackBarEvent>(),
        hasLength(1),
        reason: '应该在提交前挡住，且给出明确提示',
      );
      // 没走到 submitForm：卡片本地状态也不能被标成已答。
      final form = message.metadata?['form'];
      expect(form is Map ? form['submitted_values'] : null, isNull);
    });
  });
}

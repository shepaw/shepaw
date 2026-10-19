import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_controller.dart';
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
  });
}

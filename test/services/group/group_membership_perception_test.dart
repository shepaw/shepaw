import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/group/group_agent_executor.dart';
import 'package:shepaw/services/group/group_interaction_handler.dart';
import 'package:shepaw/services/group/group_membership_perception.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../storage/test_harness.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// Records one [GroupAgentExecutor.processGroupAgent] invocation.
class _TurnCall {
  final String agentId;
  final String channelId;
  final String content;
  final bool isAdmin;
  final String? customSystemPrompt;

  _TurnCall({
    required this.agentId,
    required this.channelId,
    required this.content,
    required this.isAdmin,
    required this.customSystemPrompt,
  });
}

/// Executor double — records calls instead of running an LLM, and optionally
/// persists a reply so the post-turn strip safety net can be asserted.
class _FakeExecutor extends GroupAgentExecutor {
  final LocalDatabaseService db;
  final List<_TurnCall> calls = [];

  /// When set, every turn persists a message with this content as the agent.
  String? replyToPersist;

  _FakeExecutor({required this.db})
      : super(
          db: db,
          uuid: const Uuid(),
          activeGroupTasks: {},
          promptBuilder: const GroupPromptBuilder(),
          interactionHandler: GroupInteractionHandler(
            db: db,
            uuid: const Uuid(),
            acpConnections: const {},
            notifyChannelUpdate: (_) {},
            loadChannelMessages: (channelId, {int limit = 100}) async =>
                const <Message>[],
          ),
          notifyChannelUpdate: (_) {},
          updateTypingAgentIds: () {},
          getOrCreateACPConnection: (_) async => throw UnimplementedError(),
        );

  @override
  Future<GroupTurnResult> processGroupAgent({
    required RemoteAgent agent,
    required String channelId,
    required String content,
    required String userId,
    required String userName,
    required String groupName,
    required String groupDescription,
    required List<RemoteAgent> allAgents,
    required List<Message> historyMessages,
    required List<String> mentionedAgentIds,
    required bool isFirstMessage,
    bool isAdmin = false,
    Map<String, dynamic>? messageVersion,
    List<ChannelMember> channelMembers = const [],
    RemoteAgent? adminAgent,
    String? customSystemPrompt,
    bool isLoopSummarize = false,
    bool isAbortSummarize = false,
    bool isDispatchNudge = false,
    bool isPendingStatusNudge = false,
    int? loopRound,
    String mentionMode = 'adminOnly',
    List<String> failedAgentNames = const [],
    List<AttachmentData>? attachments,
    ACPCancellationToken? acpCancellationToken,
    void Function(String agentId, String agentName, String chunk)?
        onStreamChunk,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    Future<Map<String, dynamic>?> Function(
      String agentId,
      String agentName,
      String interactionType,
      Map<String, dynamic> data,
    )? onInteractionRequest,
    bool isFlowMode = false,
    bool isClosingSummary = false,
    bool isWorkflowStep = false,
    String? workflowId,
    String? workflowStepId,
    String? orchestrationTraceId,
  }) async {
    calls.add(_TurnCall(
      agentId: agent.id,
      channelId: channelId,
      content: content,
      isAdmin: isAdmin,
      customSystemPrompt: customSystemPrompt,
    ));
    if (replyToPersist != null) {
      await db.createMessage(
        id: 'perception_msg_${calls.length}_${agent.id}',
        channelId: channelId,
        senderId: agent.id,
        senderType: 'agent',
        senderName: agent.name,
        content: replyToPersist!,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    return const GroupTurnResult();
  }
}

/// ACP connection double whose connectivity is pinned.
class _FakeAcpConnection extends ACPAgentConnection {
  _FakeAcpConnection({required super.agentId, required bool connected})
      : _connected = connected;

  final bool _connected;

  @override
  bool get isConnected => _connected;
}

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

RemoteAgent _agent({
  required String id,
  required String name,
  Map<String, dynamic> metadata = const {},
  ProtocolType protocol = ProtocolType.acp,
  ConnectionType connectionType = ConnectionType.websocket,
}) {
  return RemoteAgent(
    id: id,
    name: name,
    token: 'token_$id',
    endpoint: 'wss://localhost/$id',
    protocol: protocol,
    connectionType: connectionType,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    metadata: metadata,
  );
}

ChannelMember _member(String id, {String type = 'agent', String role = 'member'}) {
  return ChannelMember(
    id: id,
    type: type,
    role: role,
    joinedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

Channel _groupChannel({
  required String id,
  required String name,
  required List<ChannelMember> members,
}) {
  return Channel(
    id: id,
    name: name,
    type: 'group',
    members: members,
    description: 'test group',
  );
}

class _Seed {
  final Channel channel;
  final String adminId;
  final _FakeExecutor executor;

  _Seed({required this.channel, required this.adminId, required this.executor});
}

/// Creates a group whose admin is a local (She) agent and persists it + the
/// agents into the shared in-memory DB.
Future<_Seed> _seedLocalAdminGroup() async {
  final db = LocalDatabaseService();
  final suffix = DateTime.now().microsecondsSinceEpoch;
  final adminId = 'admin_$suffix';
  final memberId = 'member_$suffix';

  final admin = _agent(
    id: adminId,
    name: 'She',
    metadata: const {'llm_provider': 'anthropic', 'llm_model': 'claude'},
  );
  final member = _agent(id: memberId, name: 'Agent B');
  await db.createRemoteAgent(admin);
  await db.createRemoteAgent(member);

  final channel = _groupChannel(
    id: 'grp_$suffix',
    name: 'Test Group',
    members: [_member(adminId, role: 'admin'), _member(memberId)],
  );
  await db.createChannel(channel, 'user');

  return _Seed(channel: channel, adminId: adminId, executor: _FakeExecutor(db: db));
}

GroupMembershipPerceptionScheduler _scheduler({
  required _FakeExecutor executor,
  Map<String, ACPAgentConnection> acpConnections = const {},
  Duration debounce = const Duration(milliseconds: 10),
}) {
  return GroupMembershipPerceptionScheduler(
    db: LocalDatabaseService(),
    executor: executor,
    acpConnections: acpConnections,
    loadChannelMessages: (channelId, {int limit = 100}) async =>
        const <Message>[],
    debounce: debounce,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('buildMembershipChangePrompt', () {
    test('renders joined / left / current member lines', () {
      final prompt = GroupMembershipPerceptionScheduler.buildMembershipChangePrompt(
        changes: const [
          MembershipChangeEvent(memberId: 'a', memberName: '甲', isJoin: true),
          MembershipChangeEvent(memberId: 'b', memberName: '乙', isJoin: true),
          MembershipChangeEvent(memberId: 'c', memberName: '丙', isJoin: false),
        ],
        currentMembers: [
          _agent(id: 'a', name: '甲'),
          _agent(id: 'b', name: '乙'),
          _agent(id: 'd', name: '丁'),
        ],
        groupName: '研发群',
      );

      expect(prompt, contains('群聊「研发群」'));
      expect(prompt, contains('加入：甲、乙'));
      expect(prompt, contains('离开：丙'));
      expect(prompt, contains('当前群成员（3 人）：甲、乙、丁'));
    });

    test('omits empty joined / left sections', () {
      final prompt = GroupMembershipPerceptionScheduler.buildMembershipChangePrompt(
        changes: const [
          MembershipChangeEvent(memberId: 'c', memberName: '丙', isJoin: false),
        ],
        currentMembers: const [],
        groupName: '研发群',
      );

      expect(prompt, isNot(contains('加入：')));
      expect(prompt, contains('离开：丙'));
      expect(prompt, contains('当前群成员（0 人）：'));
    });

    test('forbids dispatch / orchestration actions', () {
      final prompt = GroupMembershipPerceptionScheduler.buildMembershipChangePrompt(
        changes: const [
          MembershipChangeEvent(memberId: 'a', memberName: '甲', isJoin: true),
        ],
        currentMembers: const [],
        groupName: '研发群',
      );

      expect(prompt, contains('不要执行任何委派或编排动作'));
      expect(prompt, contains('不要调用任何工具'));
    });
  });

  group('canAdminExecuteTurn', () {
    test('local admin can always execute', () {
      final admin = _agent(
        id: 'a',
        name: 'She',
        metadata: const {'llm_provider': 'anthropic'},
      );
      expect(
        GroupMembershipPerceptionScheduler.canAdminExecuteTurn(
          adminAgent: admin,
          acpConnections: const {},
        ),
        isTrue,
      );
    });

    test('peer admin can always execute', () {
      final admin = _agent(
        id: 'p',
        name: 'Peer',
        protocol: ProtocolType.peer,
      );
      expect(
        GroupMembershipPerceptionScheduler.canAdminExecuteTurn(
          adminAgent: admin,
          acpConnections: const {},
        ),
        isTrue,
      );
    });

    test('remote ACP admin requires a live connection', () {
      final admin = _agent(id: 'r', name: 'Remote');
      expect(
        GroupMembershipPerceptionScheduler.canAdminExecuteTurn(
          adminAgent: admin,
          acpConnections: const {},
        ),
        isFalse,
      );
      expect(
        GroupMembershipPerceptionScheduler.canAdminExecuteTurn(
          adminAgent: admin,
          acpConnections: {
            'r': _FakeAcpConnection(agentId: 'r', connected: false),
          },
        ),
        isFalse,
      );
      expect(
        GroupMembershipPerceptionScheduler.canAdminExecuteTurn(
          adminAgent: admin,
          acpConnections: {
            'r': _FakeAcpConnection(agentId: 'r', connected: true),
          },
        ),
        isTrue,
      );
    });
  });

  group('scheduler', () {
    test('coalesces rapid changes into one admin turn', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: 'm1',
        memberName: '甲',
        isJoin: true,
      );
      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: 'm2',
        memberName: '乙',
        isJoin: true,
      );
      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: 'm3',
        memberName: '丙',
        isJoin: false,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, hasLength(1));

      final call = seed.executor.calls.single;
      expect(call.agentId, seed.adminId);
      expect(call.channelId, seed.channel.id);
      expect(call.isAdmin, isTrue);
      expect(
        call.customSystemPrompt,
        GroupMembershipPerceptionScheduler.perceptionSystemPrompt,
      );
      expect(call.content, contains('加入：甲、乙'));
      expect(call.content, contains('离开：丙'));

      // A later change triggers a second, distinct turn.
      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: 'm4',
        memberName: '丁',
        isJoin: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, hasLength(2));
    });

    test('drops the admin\'s own membership change', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: seed.adminId,
        memberName: 'She',
        isJoin: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, isEmpty);
    });

    test('null channel is a silent no-op', () async {
      final executor = _FakeExecutor(db: LocalDatabaseService());
      final scheduler = _scheduler(executor: executor);

      scheduler.schedule(
        channelId: 'does_not_exist',
        memberId: 'm1',
        memberName: '甲',
        isJoin: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(executor.calls, isEmpty);
    });

    test('group without an admin is a silent no-op', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final memberId = 'plain_$suffix';
      await db.createRemoteAgent(_agent(id: memberId, name: 'Agent B'));

      final channel = _groupChannel(
        id: 'plain_grp_$suffix',
        name: 'No Admin Group',
        members: [_member(memberId)],
      );
      await db.createChannel(channel, 'user');

      final executor = _FakeExecutor(db: db);
      final scheduler = _scheduler(executor: executor);

      scheduler.schedule(
        channelId: channel.id,
        memberId: memberId,
        memberName: 'Agent B',
        isJoin: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(executor.calls, isEmpty);
    });

    test('offline remote ACP admin is a silent no-op', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final adminId = 'offline_admin_$suffix';
      await db.createRemoteAgent(_agent(id: adminId, name: 'Remote Admin'));

      final channel = _groupChannel(
        id: 'offline_grp_$suffix',
        name: 'Offline Group',
        members: [_member(adminId, role: 'admin')],
      );
      await db.createChannel(channel, 'user');

      final executor = _FakeExecutor(db: db);
      final scheduler = _scheduler(executor: executor);

      scheduler.schedule(
        channelId: channel.id,
        memberId: 'some_member',
        memberName: 'Member',
        isJoin: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(executor.calls, isEmpty);
    });

    test('strips a leaked dispatch JSON block after the turn', () async {
      final seed = await _seedLocalAdminGroup();
      seed.executor.replyToPersist = '好的，我已知悉。\n```json\n{"steps":[]}\n```';
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(
        channelId: seed.channel.id,
        memberId: 'm1',
        memberName: '甲',
        isJoin: true,
      );

      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(seed.executor.calls, hasLength(1));

      final rows =
          await LocalDatabaseService().getChannelMessages(seed.channel.id);
      final reply =
          rows.where((m) => m['sender_id'] == seed.adminId).firstOrNull;
      expect(reply, isNotNull);
      expect(reply!['content'] as String, isNot(contains('```json')));
    });
  });
}

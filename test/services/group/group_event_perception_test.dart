import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/group/group_agent_executor.dart';
import 'package:shepaw/services/group/group_event.dart';
import 'package:shepaw/services/group/group_event_perception.dart';
import 'package:shepaw/services/group/group_event_store.dart';
import 'package:shepaw/services/group/group_interaction_handler.dart';
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

// ---------------------------------------------------------------------------
// Builders
// ---------------------------------------------------------------------------

RemoteAgent _agent({
  required String id,
  required String name,
  Map<String, dynamic> metadata = const {},
  ProtocolType protocol = ProtocolType.acp,
}) {
  return RemoteAgent(
    id: id,
    name: name,
    token: 'token_$id',
    endpoint: 'wss://localhost/$id',
    protocol: protocol,
    connectionType: ConnectionType.websocket,
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
  final String memberId;
  final _FakeExecutor executor;

  _Seed({
    required this.channel,
    required this.adminId,
    required this.memberId,
    required this.executor,
  });
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

  return _Seed(
    channel: channel,
    adminId: adminId,
    memberId: memberId,
    executor: _FakeExecutor(db: db),
  );
}

GroupEventPerceptionScheduler _scheduler({
  required _FakeExecutor executor,
  GroupEventStore? eventStore,
  Map<String, ACPAgentConnection> acpConnections = const {},
  Duration debounce = const Duration(milliseconds: 10),
}) {
  return GroupEventPerceptionScheduler(
    db: LocalDatabaseService(),
    executor: executor,
    acpConnections: acpConnections,
    loadChannelMessages: (channelId, {int limit = 100}) async =>
        const <Message>[],
    eventStore: eventStore,
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

  group('renderEventLine', () {
    test('renders step events with 1-based stage/step and member', () {
      final e = GroupEvent.stepCompleted(
        id: 'e1',
        channelId: 'g',
        stageIndex: 0,
        stepIndex: 2,
        agentName: 'Agent B',
        summary: '产出 X',
      );
      final line = renderEventLine(e);
      expect(line, contains('阶段1/步骤3'));
      expect(line, contains('成员Agent B'));
      expect(line, contains('✅ 完成'));
      expect(line, contains('产出 X'));
    });

    test('renders failure with error summary', () {
      final e = GroupEvent.stepFailed(
        id: 'e2',
        channelId: 'g',
        stageIndex: 1,
        stepIndex: 0,
        agentName: 'Agent C',
        error: '超时',
      );
      final line = renderEventLine(e);
      expect(line, contains('阶段2/步骤1'));
      expect(line, contains('❌ 失败'));
      expect(line, contains('超时'));
    });

    test('renders membership lines', () {
      expect(
        renderEventLine(GroupEvent.memberChange(
          id: 'e3',
          channelId: 'g',
          memberId: 'm1',
          memberName: '甲',
          isJoin: true,
        )),
        contains('成员加入：甲'),
      );
      expect(
        renderEventLine(GroupEvent.memberChange(
          id: 'e4',
          channelId: 'g',
          memberId: 'm1',
          memberName: '甲',
          isJoin: false,
        )),
        contains('成员离开：甲'),
      );
    });

    test('loopRoundCompleted factory fills round/delegated/failed payload', () {
      final e = GroupEvent.loopRoundCompleted(
        id: 'r1',
        channelId: 'g',
        round: 2,
        delegatedAgentNames: const ['Agent B', 'Agent C'],
        failedAgentNames: const ['Agent C'],
        summary: '完成初稿',
      );
      expect(e.type, GroupEventType.loopRoundCompleted);
      expect(e.round, 2);
      expect(e.payload['round'], 2);
      expect(e.payload['delegated'], ['Agent B', 'Agent C']);
      expect(e.payload['failed'], ['Agent C']);
      expect(e.summary, '完成初稿');
    });

    test('loopRoundCompleted omits empty delegated/failed lists', () {
      final e = GroupEvent.loopRoundCompleted(
        id: 'r2',
        channelId: 'g',
        round: 1,
      );
      expect(e.payload.containsKey('delegated'), isFalse);
      expect(e.payload.containsKey('failed'), isFalse);
    });

    test('renders loop round line with round, executors, failures and summary', () {
      final e = GroupEvent.loopRoundCompleted(
        id: 'r3',
        channelId: 'g',
        round: 3,
        delegatedAgentNames: const ['Agent B', 'Agent C'],
        failedAgentNames: const ['Agent C'],
        summary: '第一轮产出已整理',
      );
      final line = renderEventLine(e);
      expect(line, contains('第3轮'));
      expect(line, contains('执行:Agent B、Agent C'));
      expect(line, contains('失败:Agent C'));
      expect(line, contains('第一轮产出已整理'));
    });

    test('renders loop round line minimal when nothing delegated/failed', () {
      final e = GroupEvent.loopRoundCompleted(
        id: 'r4',
        channelId: 'g',
        round: 1,
      );
      final line = renderEventLine(e);
      expect(line, '编排第1轮完成');
    });
  });

  group('isWorkflowStepEvent', () {
    test('true only for step / stage events', () {
      expect(
        isWorkflowStepEvent(GroupEvent.stepCompleted(
          id: 'a',
          channelId: 'g',
          stageIndex: 0,
          stepIndex: 0,
        )),
        isTrue,
      );
      expect(
        isWorkflowStepEvent(GroupEvent.memberChange(
          id: 'b',
          channelId: 'g',
          memberId: 'm',
          memberName: 'M',
          isJoin: true,
        )),
        isFalse,
      );
    });
  });

  group('GroupEventStore', () {
    test('recent returns latest events oldest-first, bounded by limit', () {
      final store = GroupEventStore();
      for (var i = 0; i < 3; i++) {
        store.record(GroupEvent.stepCompleted(
          id: 'e$i',
          channelId: 'g',
          stageIndex: 0,
          stepIndex: i,
          agentName: 'A$i',
        ));
      }
      final recent = store.recent('g', limit: 2);
      expect(recent.map((e) => e.id), ['e1', 'e2']);
      expect(recent, hasLength(2));
    });

    test('ring buffer caps at 50 per channel', () {
      final store = GroupEventStore();
      for (var i = 0; i < 60; i++) {
        store.record(GroupEvent.stepCompleted(
          id: 'e$i',
          channelId: 'g',
          stageIndex: 0,
          stepIndex: i,
        ));
      }
      final recent = store.recent('g', limit: 100);
      expect(recent, hasLength(50));
      expect(recent.first.id, 'e10');
    });

    test('onPersist hook is called with a monotonic seq', () {
      final persisted = <(String, int)>[];
      final store = GroupEventStore(
        onPersist: (event, seq) async {
          persisted.add((event.id, seq));
        },
      );
      store.record(GroupEvent.stepCompleted(
        id: 'a',
        channelId: 'g',
        stageIndex: 0,
        stepIndex: 0,
      ));
      store.record(GroupEvent.stepFailed(
        id: 'b',
        channelId: 'g',
        stageIndex: 0,
        stepIndex: 1,
        agentName: 'B',
      ));
      expect(persisted, [('a', 1), ('b', 2)]);
    });
  });

  group('buildGenericPerceptionPrompt', () {
    test('renders event lines, roster, and forbids dispatch', () {
      final prompt = buildGenericPerceptionPrompt(
        groupName: '研发群',
        events: [
          GroupEvent.stepCompleted(
            id: 'a',
            channelId: 'g',
            stageIndex: 0,
            stepIndex: 0,
            agentName: 'Agent B',
            summary: '产出 X',
          ),
          GroupEvent.stepFailed(
            id: 'b',
            channelId: 'g',
            stageIndex: 0,
            stepIndex: 1,
            agentName: 'Agent C',
            error: '超时',
          ),
        ],
        currentMembers: [_agent(id: 'x', name: 'She')],
      );
      expect(prompt, contains('群聊「研发群」'));
      expect(prompt, contains('阶段1/步骤1'));
      expect(prompt, contains('❌ 失败'));
      expect(prompt, contains('当前群成员（1 人）：She'));
      expect(prompt, contains('不要执行任何委派或编排动作'));
      expect(prompt, contains('不要调用任何工具'));
    });
  });

  group('scheduler', () {
    test('passive stepCompleted alone never triggers a turn', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(GroupEvent.stepCompleted(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.memberId,
        agentName: 'Agent B',
        summary: '产出 X',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, isEmpty);
    });

    test('stepFailed triggers one admin turn; content merges recent passive '
        'events from the store', () async {
      final seed = await _seedLocalAdminGroup();
      final store = GroupEventStore();
      final scheduler = _scheduler(executor: seed.executor, eventStore: store);

      // 失败前刚完成的节点（被动）→ 事件日志；随后失败（主动）→ 触发回合。
      scheduler.schedule(GroupEvent.stepCompleted(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.memberId,
        agentName: 'Agent B',
        summary: '产出 X',
      ));
      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 1,
        agentId: seed.memberId,
        agentName: 'Agent B',
        error: '超时',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, hasLength(1));

      final call = seed.executor.calls.single;
      expect(call.agentId, seed.adminId);
      expect(call.channelId, seed.channel.id);
      expect(call.isAdmin, isTrue);
      expect(
        call.customSystemPrompt,
        genericPerceptionSystemPrompt,
      );
      // 两条事件都在：失败前的成功节点 + 失败节点。
      expect(call.content, contains('阶段1/步骤1'));
      expect(call.content, contains('✅ 完成'));
      expect(call.content, contains('阶段1/步骤2'));
      expect(call.content, contains('❌ 失败'));
      expect(call.content, contains('超时'));
    });

    test('rapid multiple failures coalesce into one turn', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.memberId,
        agentName: 'Agent B',
        error: 'e1',
      ));
      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 1,
        agentId: seed.memberId,
        agentName: 'Agent C',
        error: 'e2',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, hasLength(1));
      expect(seed.executor.calls.single.content, contains('e1'));
      expect(seed.executor.calls.single.content, contains('e2'));
    });

    test('drops events owned by the admin itself', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.adminId,
        agentName: 'She',
        error: 'admin error',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, isEmpty);
    });

    test('cancelPendingForChannel drops a not-yet-fired turn', () async {
      final seed = await _seedLocalAdminGroup();
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.memberId,
        agentName: 'Agent B',
        error: 'boom',
      ));
      scheduler.cancelPendingForChannel(seed.channel.id);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(seed.executor.calls, isEmpty);
    });

    test('null channel is a silent no-op', () async {
      final executor = _FakeExecutor(db: LocalDatabaseService());
      final scheduler = _scheduler(executor: executor);

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: 'does_not_exist',
        stageIndex: 0,
        stepIndex: 0,
        agentName: 'Agent B',
        error: 'x',
      ));

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

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: memberId,
        agentName: 'Agent B',
        error: 'x',
      ));

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

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentName: 'Member',
        error: 'x',
      ));

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(executor.calls, isEmpty);
    });

    test('strips a leaked dispatch JSON block after the turn', () async {
      final seed = await _seedLocalAdminGroup();
      seed.executor.replyToPersist = '好的，我已知悉。\n```json\n{"steps":[]}\n```';
      final scheduler = _scheduler(executor: seed.executor);

      scheduler.schedule(GroupEvent.stepFailed(
        channelId: seed.channel.id,
        stageIndex: 0,
        stepIndex: 0,
        agentId: seed.memberId,
        agentName: 'Agent B',
        error: 'boom',
      ));

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

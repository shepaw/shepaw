import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/group/group_agent_executor.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_event.dart';
import 'package:shepaw/services/group/group_event_store.dart';
import 'package:shepaw/services/group/group_interaction_handler.dart';
import 'package:shepaw/services/group/group_member_session_service.dart';
import 'package:shepaw/services/group/group_membership_perception.dart';
import 'package:shepaw/services/group/group_orchestration_tools.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';
import 'package:shepaw/services/group/group_session_service.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:uuid/uuid.dart';

import '../../storage/test_harness.dart';

/// L 系列低严重度修复的单元测试。
///
/// 覆盖 L9/L10/L11/L12/L14/L16/L18 的纯逻辑与 DB 层行为；L1/L3/L6/L13 等
/// 依赖完整编排/流式执行，以代码核对 + 全量回归验证（与既有深路径一致）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('L9: clearAllGroupSessions 重建父群补全字段', () {
    test('重建后的父群保留家族链/门闸/循环等配置', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final parentId = 'parent_$suffix';
      final childId = 'child_$suffix';

      final member = _member('agent_$suffix');
      final parent = Channel(
        id: parentId,
        name: 'Family',
        type: 'group',
        members: [member],
        description: 'parent',
      );
      await db.createChannel(parent, 'user');

      // 子会话带齐全部字段（重建父群的来源）。
      final child = Channel(
        id: childId,
        name: 'Family Session',
        type: 'group',
        members: [member],
        description: 'child',
        parentGroupId: parentId,
        sourceSheChannelId: 'she_$suffix',
        systemPrompt: 'sys',
        maxLoopRounds: 5,
        mentionMode: 'allMembers',
        flowMode: true,
        enableStageGate: true,
      );
      await db.createChannel(child, 'user');

      // 模拟父群被删除：clearAllGroupSessions 需重建它。
      await db.deleteChannel(parentId);

      final service = GroupSessionService(
        db: db,
        uuid: const Uuid(),
        acpConnections: const {},
        notifyChannelUpdate: (_) {},
      );
      await service.clearAllGroupSessions(
        parentGroupId: parentId,
        currentChannelId: parentId,
        agentIds: const [],
      );

      final rebuilt = await db.getChannelById(parentId);
      expect(rebuilt, isNotNull, reason: '父群应在清除后重建');
      expect(rebuilt!.parentGroupId, child.parentGroupId);
      expect(rebuilt.sourceSheChannelId, child.sourceSheChannelId);
      expect(rebuilt.systemPrompt, child.systemPrompt);
      expect(rebuilt.maxLoopRounds, child.maxLoopRounds);
      expect(rebuilt.mentionMode, child.mentionMode);
      expect(rebuilt.flowMode, isTrue);
      expect(rebuilt.enableStageGate, isTrue);
    });
  });

  group('L10: ensureMemberSession 并发不再重复引导消息', () {
    test('两次并发 ensure 只产生一条引导系统消息', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final groupId = 'grp_$suffix';
      final agentId = 'agent_$suffix';

      final group = Channel(
        id: groupId,
        name: 'Concurrent Group',
        type: 'group',
        members: [_member(agentId)],
        description: 'test',
      );
      await db.createChannel(group, 'user');

      final service = GroupMemberSessionService(db);
      final sessionId = GroupMemberSessionService.memberSessionId(groupId, agentId);

      await Future.wait([
        service.ensureMemberSession(
          groupChannel: group,
          agentId: agentId,
          userId: 'user',
        ),
        service.ensureMemberSession(
          groupChannel: group,
          agentId: agentId,
          userId: 'user',
        ),
      ]);

      final messages = await db.getChannelMessages(sessionId, limit: 100);
      final bootstrap = messages
          .where((m) => (m['id'] as String? ?? '').startsWith('sys_gmd_'))
          .length;
      expect(bootstrap, 1,
          reason: 'L10 确定性 id + ignore 应只保留一条引导消息（旧实现按毫秒时间戳可能插两条）');
    });
  });

  group('L11: dispatch mode 校验', () {
    test('GroupDispatchParser 非法 mode 回退 concurrent 且不抛错', () async {
      final db = LocalDatabaseService();
      final parser = GroupDispatchParser(db);
      final agents = [_remoteAgent('a1', 'Agent A')];

      final result = parser.parseStructuredDispatch(
        '```json\n{"dispatch": {"mode": "parallel", "steps": '
        '[{"step": 1, "agents": ["Agent A"], "task": "t"}]}, "done": false}\n```',
        agents,
      );

      expect(result.steps, hasLength(1));
      expect(result.steps.first.mode, 'concurrent',
          reason: 'L11 非法 mode 回退 concurrent，但记日志告警');
      expect(result.parseError, isNull);
    });

    test('GroupOrchestrationTools.parseDispatchArgs 非法 mode 回退 concurrent', () {
      final args = <String, dynamic>{
        'mode': 'parallel',
        'steps': [
          {'step': 1, 'agents': ['Agent A'], 'task': 't'},
        ],
      };
      final result = GroupOrchestrationTools.parseDispatchArgs(
        args,
        [_remoteAgent('a1', 'Agent A')],
      );

      expect(result.steps, hasLength(1));
      expect(result.steps.first.mode, 'concurrent');
    });
  });

  group('L12: mirrorTurn 无 sourceMessageId 不冲突', () {
    test('两次镜像（null sourceMessageId）生成互异消息 id', () async {
      final db = LocalDatabaseService();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final groupId = 'grp_$suffix';
      final agentId = 'agent_$suffix';
      final sessionId = 'gmd_${groupId}__$agentId';

      final group = Channel(
        id: groupId,
        name: 'Mirror Group',
        type: 'group',
        members: [_member(agentId)],
        description: 'test',
      );
      await db.createChannel(group, 'user');

      final service = GroupMemberSessionService(db);
      final memberSession = await service.ensureMemberSession(
        groupChannel: group,
        agentId: agentId,
        userId: 'user',
      );
      expect(memberSession, sessionId);

      await service.mirrorTurn(
        memberSessionId: sessionId,
        groupChannelId: groupId,
        userId: 'user',
        userName: 'User',
        inboundContent: 'req-1',
        agentId: agentId,
        agentName: 'Agent A',
        replyContent: 'reply-1',
      );
      await service.mirrorTurn(
        memberSessionId: sessionId,
        groupChannelId: groupId,
        userId: 'user',
        userName: 'User',
        inboundContent: 'req-2',
        agentId: agentId,
        agentName: 'Agent A',
        replyContent: 'reply-2',
      );

      final messages = await db.getChannelMessages(sessionId, limit: 100);
      final requestIds =
          messages.where((m) => (m['id'] as String? ?? '').startsWith('gmdreq_')).toList();
      expect(requestIds, hasLength(2));
      expect(requestIds[0]['id'], isNot(requestIds[1]['id']),
          reason: 'L12 uuid 兜底应保证两次镜像 id 互异（旧实现微秒时间戳可能同微秒冲突）');
    });
  });

  group('L14: 成员进出写入共享事件日志', () {
    test('membership scheduler 触发 schedule 后事件进入 eventStore', () {
      final store = GroupEventStore();
      final executor = _NoopExecutor(db: LocalDatabaseService());
      final scheduler = GroupMembershipPerceptionScheduler(
        db: LocalDatabaseService(),
        executor: executor,
        acpConnections: const {},
        loadChannelMessages: (channelId, {int limit = 100}) async =>
            const <Message>[],
        eventStore: store,
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(scheduler.dispose);

      scheduler.schedule(
        channelId: 'grp_x',
        memberId: 'agent_b',
        memberName: 'Agent B',
        isJoin: true,
      );

      final events = store.recent('grp_x', limit: 10);
      expect(events, hasLength(1));
      expect(events.first.type, GroupEventType.memberJoined);
      expect(events.first.agentId, 'agent_b');
    });
  });

  group('L16: GroupEventStore 频道键上限', () {
    test('超过上限后最旧频道被淘汰，新区块保留', () {
      final store = GroupEventStore();
      for (var i = 0; i < 105; i++) {
        store.record(GroupEvent.stepCompleted(
          channelId: 'chan_$i',
          stageIndex: 0,
          stepIndex: 0,
          agentId: 'agent_$i',
          agentName: 'Agent $i',
          summary: 's$i',
        ));
      }
      // 最旧的 5 个频道（chan_0..chan_4）被淘汰。
      expect(store.recent('chan_0', limit: 10), isEmpty);
      expect(store.recent('chan_4', limit: 10), isEmpty);
      // 淘汰边界上的第一个幸存者保留。
      expect(store.recent('chan_5', limit: 10), hasLength(1));
      // 最新的频道仍在。
      expect(store.recent('chan_104', limit: 10), hasLength(1));
      // 内部频道数不超过上限。
      expect(store.channelCountForTest, lessThanOrEqualTo(100));
    });
  });

  group('L18: GroupEventStore.onPersist 同步抛错不传播', () {
    test('同步 throw 的 onPersist 被吞掉，record 不抛', () {
      final store = GroupEventStore(
        onPersist: (event, seq) => throw StateError('boom'),
      );
      Object? escaped;
      try {
        store.record(GroupEvent.stepCompleted(
          channelId: 'chan_x',
          stageIndex: 0,
          stepIndex: 0,
          agentId: 'agent_x',
          agentName: 'Agent X',
          summary: 's',
        ));
      } catch (e) {
        escaped = e;
      }
      expect(escaped, isNull,
          reason: 'L18 同步抛错应被吞掉，绝不让调用方 record 抛错');
      expect(store.recent('chan_x', limit: 10), hasLength(1));
    });
  });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ChannelMember _member(String id, {String type = 'agent', String role = 'member'}) {
  return ChannelMember(
    id: id,
    type: type,
    role: role,
    joinedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

RemoteAgent _remoteAgent(String id, String name) {
  return RemoteAgent(
    id: id,
    name: name,
    token: 'token_$id',
    endpoint: 'wss://localhost/$id',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.websocket,
    createdAt: DateTime.now().millisecondsSinceEpoch,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
    metadata: const {},
  );
}

/// 不实际跑 LLM 的执行器替身——L14 只测 schedule→eventStore 链路，回合在
/// debounce 窗口内不会触发，若触发即抛错暴露测试假设被打破。
class _NoopExecutor extends GroupAgentExecutor {
  _NoopExecutor({required LocalDatabaseService db})
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
    void Function(String agentId, String agentName, Map<String, dynamic>)?
        onMessageMetadata,
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
    throw StateError(
      'L14 test: perception turn should not run within debounce window',
    );
  }
}

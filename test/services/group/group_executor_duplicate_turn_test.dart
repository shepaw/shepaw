import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/acp_agent_connection.dart';
import 'package:shepaw/services/group/group_agent_executor.dart';
import 'package:shepaw/services/group/group_interaction_handler.dart';
import 'package:shepaw/services/group/group_prompt_builder.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/task/task_models.dart';
import 'package:uuid/uuid.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('M5 duplicate-turn guard', () {
    late LocalDatabaseService db;
    late Map<String, Map<String, GroupActiveTask>> activeTasks;
    late GroupAgentExecutor executor;
    late RemoteAgent peerAgent;
    int typingCalls = 0;
    final List<(String, String, bool)> doneCalls = [];

    RemoteAgent buildPeerAgent(String id, String name) => RemoteAgent(
          id: id,
          name: name,
          avatar: '🤖',
          token: 't',
          endpoint: 'peer://pair',
          protocol: ProtocolType.peer,
          // No source_peer_id / remote_agent_id metadata → peer path hits the
          // "missing metadata" branch and returns deterministically without a
          // real LLM/ACP round.
          connectionType: ConnectionType.websocket,
          createdAt: 0,
          updatedAt: 0,
        );

    setUp(() async {
      db = LocalDatabaseService();
      await db.database;
      activeTasks = <String, Map<String, GroupActiveTask>>{};
      typingCalls = 0;
      doneCalls.clear();
      peerAgent = buildPeerAgent('agent-x', '小X');
      executor = GroupAgentExecutor(
        db: db,
        uuid: const Uuid(),
        activeGroupTasks: activeTasks,
        promptBuilder: const GroupPromptBuilder(),
        interactionHandler: GroupInteractionHandler(
          db: db,
          uuid: const Uuid(),
          acpConnections: <String, ACPAgentConnection>{},
          notifyChannelUpdate: (_) {},
          loadChannelMessages: (channelId, {int limit = 100}) async =>
              <Message>[],
        ),
        notifyChannelUpdate: (_) {},
        updateTypingAgentIds: () => typingCalls++,
        getOrCreateACPConnection: (_) async =>
            throw UnimplementedError('not reached in these tests'),
      );
    });

    Future<GroupTurnResult> runTurn({String channelId = 'ch-a'}) {
      return executor.processGroupAgent(
        agent: peerAgent,
        channelId: channelId,
        content: 'hello',
        userId: 'local-user',
        userName: '用户',
        groupName: '测试群',
        groupDescription: 'desc',
        allAgents: [peerAgent],
        historyMessages: const <Message>[],
        mentionedAgentIds: const [],
        isFirstMessage: false,
        isAdmin: false,
        mentionMode: 'adminOnly',
        channelMembers: const <ChannelMember>[],
        onAgentDone: (id, name, skipped) =>
            doneCalls.add((id, name, skipped)),
      );
    }

    test('in-flight duplicate is skipped without overwriting the active task', () async {
      // A turn is already in flight for (ch-a, agent-x).
      final inflight = GroupActiveTask(
        agentId: peerAgent.id,
        agentName: peerAgent.name,
        channelId: 'ch-a',
      );
      activeTasks.putIfAbsent('ch-a', () => <String, GroupActiveTask>{})[peerAgent.id] = inflight;

      final result = await runTurn();

      // Guard fires: empty result, skipped=true reported exactly once.
      expect(result.content, isEmpty);
      expect(doneCalls, hasLength(1));
      expect(doneCalls.single.$1, peerAgent.id);
      expect(doneCalls.single.$2, peerAgent.name);
      expect(doneCalls.single.$3, isTrue);

      // The pre-existing task object is untouched (not re-registered/removed).
      expect(identical(activeTasks['ch-a']![peerAgent.id], inflight), isTrue);
      // updateTypingAgentIds is only called after registration, which the
      // guard bypasses — so it must NOT have fired.
      expect(typingCalls, 0);
    });

    test('guard is per-(channel, agent): a complete task does not block a new turn', () async {
      // A previously-finished turn is still in the map but marked complete.
      final finished = GroupActiveTask(
        agentId: peerAgent.id,
        agentName: peerAgent.name,
        channelId: 'ch-a',
      );
      finished.isComplete = true;
      activeTasks.putIfAbsent('ch-a', () => <String, GroupActiveTask>{})[peerAgent.id] = finished;

      try {
        await runTurn();
      } catch (_) {
        // The turn proceeds past the guard (complete task) and the peer path
        // may fail on the missing-channel DB write — that's expected. What
        // matters is the guard did NOT short-circuit: registration happened,
        // which fires updateTypingAgentIds before any later path.
      }

      // Guard bypassed → a fresh task was registered → typing update fired
      // (the guard path never reaches registration).
      expect(typingCalls, greaterThan(0));
      // The seeded task was replaced by a fresh one (either still registered
      // or already cleaned up by the peer path) — in no case is the completed
      // task still the map's current value.
      expect(identical(activeTasks['ch-a']?[peerAgent.id], finished), isFalse);
    });

    test('guard does not block a different agent in the same channel', () async {
      final inflight = GroupActiveTask(
        agentId: peerAgent.id,
        agentName: peerAgent.name,
        channelId: 'ch-a',
      );
      activeTasks.putIfAbsent('ch-a', () => <String, GroupActiveTask>{})[peerAgent.id] = inflight;

      // Same channel, different agent → the guard key is (channel, agent).
      final other = buildPeerAgent('agent-y', '小Y');
      final otherExecutor = GroupAgentExecutor(
        db: db,
        uuid: const Uuid(),
        activeGroupTasks: activeTasks,
        promptBuilder: const GroupPromptBuilder(),
        interactionHandler: GroupInteractionHandler(
          db: db,
          uuid: const Uuid(),
          acpConnections: <String, ACPAgentConnection>{},
          notifyChannelUpdate: (_) {},
          loadChannelMessages: (channelId, {int limit = 100}) async =>
              <Message>[],
        ),
        notifyChannelUpdate: (_) {},
        updateTypingAgentIds: () => typingCalls++,
        getOrCreateACPConnection: (_) async =>
            throw UnimplementedError('not reached in these tests'),
      );
      final done = <(String, String, bool)>[];
      try {
        await otherExecutor.processGroupAgent(
          agent: other,
          channelId: 'ch-a',
          content: 'hello',
          userId: 'local-user',
          userName: '用户',
          groupName: '测试群',
          groupDescription: 'desc',
          allAgents: [other],
          historyMessages: const <Message>[],
          mentionedAgentIds: const [],
          isFirstMessage: false,
          isAdmin: false,
          mentionMode: 'adminOnly',
          channelMembers: const <ChannelMember>[],
          onAgentDone: (id, name, skipped) => done.add((id, name, skipped)),
        );
      } catch (_) {
        // Same as above: proceeds past the guard into the peer path.
      }

      // agent-y was registered (its own turn), so typing fired for it.
      expect(typingCalls, greaterThan(0));
      // agent-x's in-flight task is still intact.
      expect(identical(activeTasks['ch-a']![peerAgent.id], inflight), isTrue);
      // The guard never reported a skip for agent-x.
      expect(done.where((c) => c.$1 == peerAgent.id), isEmpty);
    });
  });
}

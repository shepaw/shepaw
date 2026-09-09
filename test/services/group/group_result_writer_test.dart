import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_result_writer.dart';
import 'package:shepaw/services/group/group_task_status.dart';
import 'package:shepaw/services/group/group_turn_result.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      token: 't',
      endpoint: 'e',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  tearDown(() {
    GroupOrchestrationFeatures.structuredResults = true;
    GroupOrchestrationFeatures.structuredTasks = true;
  });

  group('GroupResultWriter.fromTurnResult', () {
    test('maps done status and extracts summary + store URIs', () {
      final member = GroupResultWriter.fromTurnResult(
        agentId: 'coder',
        agentName: 'Coder',
        turn: const GroupTurnResult(
          content: '实现完成，见 store://workspaces/dev/out.md\n[TASK_STATUS: done]',
        ),
        round: 2,
      );

      expect(member, isNotNull);
      expect(member!.taskStatus, GroupTaskMemberResult.statusDone);
      expect(member.summary, contains('实现完成'));
      expect(member.artifactUris, contains('store://workspaces/dev/out.md'));
      expect(member.round, 2);
    });

    test('marks failed agents explicitly', () {
      final member = GroupResultWriter.fromTurnResult(
        agentId: 'coder',
        agentName: 'Coder',
        turn: const GroupTurnResult(content: ''),
        round: 1,
        failedAgentNames: ['Coder'],
      );

      expect(member!.taskStatus, GroupTaskMemberResult.statusFailed);
    });

    test('marks stalled agents before hard fail', () {
      final member = GroupResultWriter.fromTurnResult(
        agentId: 'coder',
        agentName: 'Coder',
        turn: const GroupTurnResult(content: ''),
        round: 1,
        stalledAgentNames: ['Coder'],
      );

      expect(member!.taskStatus, GroupTaskMemberResult.statusStalled);
    });

    test('skips empty non-applicable turns', () {
      expect(
        GroupResultWriter.fromTurnResult(
          agentId: 'coder',
          agentName: 'Coder',
          turn: const GroupTurnResult(content: '[SKIP]'),
          round: 1,
        ),
        isNull,
      );
    });
  });

  group('GroupResultWriter.buildPeerResultsNote', () {
    test('lists same-round peers excluding self', () {
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'coder',
            agentName: 'Coder',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'API 已实现',
          ),
          GroupTaskMemberResult(
            agentId: 'qa',
            agentName: 'QA',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: '测试已通过',
          ),
        ],
      );

      final note = GroupResultWriter.buildPeerResultsNote(
        results: results,
        selfAgentId: 'qa',
        round: 1,
      );

      expect(note, contains('【同轮完成情况】'));
      expect(note, contains('Coder'));
      expect(note, contains('API 已实现'));
      expect(note, isNot(contains('QA')));
    });

    test('GroupDispatchParser wrapper matches writer output', () {
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'a',
            agentName: 'A',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'done work',
          ),
        ],
      );
      expect(
        GroupDispatchParser.buildPeerResultsNote(
          results: results,
          selfAgentId: 'b',
          round: 1,
        ),
        GroupResultWriter.buildPeerResultsNote(
          results: results,
          selfAgentId: 'b',
          round: 1,
        ),
      );
    });
  });

  group('GroupResultWriter.persistFromTurns', () {
    test('writes results.json in workspace', () async {
      final ws = GroupWorkspaceService.instance;
      const groupId = 'group_results_writer';
      const orchId = 'orch-results-1';

      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'coder', role: 'member')],
      );
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'sess',
        userGoal: '写 results',
      );

      await GroupResultWriter.persistFromTurns(
        groupId: groupId,
        orchestrationId: orchId,
        turns: {
          'coder': const GroupTurnResult(
            content: '完成文档 store://workspaces/dev/doc.md\n[TASK_STATUS: done]',
          ),
        },
        agents: [_agent('coder', 'Coder')],
        round: 1,
      );

      final results = await ws.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(results!.members.single.agentName, 'Coder');
      expect(results.members.single.taskStatus, GroupTaskMemberResult.statusDone);
      expect(results.members.single.summary, contains('完成文档'));
    });
  });

  group('GroupResultWriter.buildAdminResultsBlock', () {
    test('formats admin summarize block', () {
      final block = GroupResultWriter.buildAdminResultsBlock(
        GroupTaskResults(
          orchestrationId: 'o1',
          members: [
            GroupTaskMemberResult(
              agentId: 'coder',
              agentName: 'Coder',
              round: 1,
              taskStatus: GroupTaskMemberResult.statusDone,
              summary: '完成 API',
              artifactUris: ['store://workspaces/dev/api.md'],
            ),
          ],
        ),
      );

      expect(block, contains('【结构化成员结果（results.json）】'));
      expect(block, contains('Coder (done'));
      expect(block, contains('store://workspaces/dev/api.md'));
    });
  });
}

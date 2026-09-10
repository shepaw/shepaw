import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_result_writer.dart';
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

    test('第 2 轮派发回退到最近已完成轮，不再恒为空', () {
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'coder',
            agentName: 'Coder',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'R1 交付',
          ),
          GroupTaskMemberResult(
            agentId: 'qa',
            agentName: 'QA',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'R1 测试',
          ),
        ],
      );

      // 第 2 轮派发时，成员结果尚未落盘，库里只有 round=1 条目。
      final note = GroupResultWriter.buildPeerResultsNote(
        results: results,
        selfAgentId: 'qa',
        round: 2,
      );

      expect(note, contains('【上一轮完成情况（第 1 轮，本轮尚未回报）】'),
          reason: '回退到上一轮时必须说清是上一轮，不能冒充同轮');
      expect(note, contains('Coder'));
      expect(note, contains('R1 交付'));
      expect(note, isNot(contains('QA')));
    });

    test('同轮已回报时仍精确匹配该轮', () {
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'coder',
            agentName: 'Coder',
            round: 1,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'R1 交付',
          ),
          GroupTaskMemberResult(
            agentId: 'coder',
            agentName: 'Coder',
            round: 2,
            taskStatus: GroupTaskMemberResult.statusDone,
            summary: 'R2 交付',
          ),
        ],
      );

      final note = GroupResultWriter.buildPeerResultsNote(
        results: results,
        selfAgentId: 'qa',
        round: 2,
      );

      expect(note, contains('R2 交付'));
      expect(note, isNot(contains('R1 交付')));
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

  group('GroupResultWriter.persistFromMembersDonePayload', () {
    Future<void> ensureTask(String groupId, String orchId) async {
      final ws = GroupWorkspaceService.instance;
      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'coder', role: 'member')],
      );
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'sess',
        userGoal: '重放 results',
      );
    }

    test('replays done member same as live persistFromTurns', () async {
      const groupId = 'group_result_writer_replay';
      const orchId = 'orch-replay-done';
      await ensureTask(groupId, orchId);
      const uri = 'store://workspaces/dev/doc.md';

      await GroupResultWriter.persistFromMembersDonePayload(
        groupId: groupId,
        orchestrationId: orchId,
        agents: [_agent('coder', 'Coder')],
        payload: {
          'status': 'members_done',
          'round': 1,
          'orchestration_id': orchId,
          'member_results': {
            'coder': {
              'content': '完成文档 $uri\n[TASK_STATUS: done]',
              'wants_continue': false,
              'is_done': true,
              'has_dispatch': false,
              'artifacts': <String>[uri],
              'task_status': 'done',
              'task_status_reason': null,
              'applicable': true,
            },
          },
          'failed_agents': <String>[],
          'stalled_agents': <String>[],
        },
      );

      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(results!.members.single.agentName, 'Coder');
      expect(results.members.single.taskStatus, GroupTaskMemberResult.statusDone);
      expect(results.members.single.summary, contains('完成文档'));
      expect(results.members.single.artifactUris, contains(uri));
    });

    test('skips [SKIP] member exactly like live path (applicable=false)', () async {
      const groupId = 'group_result_writer_replay';
      const orchId = 'orch-replay-skip';
      await ensureTask(groupId, orchId);

      await GroupResultWriter.persistFromMembersDonePayload(
        groupId: groupId,
        orchestrationId: orchId,
        agents: [_agent('coder', 'Coder')],
        payload: {
          'status': 'members_done',
          'round': 1,
          'orchestration_id': orchId,
          'member_results': {
            'coder': {
              'content': '[SKIP] 与我的职责无关',
              'wants_continue': false,
              'is_done': false,
              'has_dispatch': false,
              'artifacts': <String>[],
              // 现场写入时 executor 解析出的 info：missing + applicable=false。
              'task_status': 'missing',
              'task_status_reason': null,
              'applicable': false,
            },
          },
          'failed_agents': <String>[],
          'stalled_agents': <String>[],
        },
      );

      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(results, isNull,
          reason: '不可用回合在 live 与 replay 两侧都不应落库为 pending');
    });

    test('rebuilds stalled member from stalled_agents (empty content)', () async {
      const groupId = 'group_result_writer_replay';
      const orchId = 'orch-replay-stall';
      await ensureTask(groupId, orchId);

      await GroupResultWriter.persistFromMembersDonePayload(
        groupId: groupId,
        orchestrationId: orchId,
        agents: [_agent('coder', 'Coder')],
        payload: {
          'status': 'members_done',
          'round': 1,
          'orchestration_id': orchId,
          'member_results': {
            'coder': {
              'content': '',
              'wants_continue': false,
              'is_done': false,
              'has_dispatch': false,
              'artifacts': <String>[],
              'task_status': null,
              'task_status_reason': null,
              'applicable': null,
            },
          },
          'failed_agents': <String>[],
          'stalled_agents': <String>['Coder'],
        },
      );

      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(results!.members.single.taskStatus, GroupTaskMemberResult.statusStalled);
      expect(results.members.single.summary, contains('未响应'));
    });

    test('skips replay when results.json already has this round', () async {
      const groupId = 'group_result_writer_replay';
      const orchId = 'orch-replay-noop';
      await ensureTask(groupId, orchId);
      final ws = GroupWorkspaceService.instance;

      // 模拟 live 侧已由 persistFromTurns 写入本轮结果。
      await ws.upsertTaskMemberResult(
        groupId: groupId,
        orchestrationId: orchId,
        memberResult: GroupTaskMemberResult(
          agentId: 'coder',
          agentName: 'Coder',
          round: 1,
          taskStatus: GroupTaskMemberResult.statusDone,
          summary: 'LIVE 已落盘',
        ),
      );

      // 重放同轮 payload：若未跳过，会覆盖为 REPLAY 内容。
      await GroupResultWriter.persistFromMembersDonePayload(
        groupId: groupId,
        orchestrationId: orchId,
        agents: [_agent('coder', 'Coder')],
        payload: {
          'status': 'members_done',
          'round': 1,
          'orchestration_id': orchId,
          'member_results': {
            'coder': {
              'content': 'REPLAY 内容\n[TASK_STATUS: done]',
              'wants_continue': false,
              'is_done': true,
              'has_dispatch': false,
              'artifacts': <String>[],
              'task_status': 'done',
              'task_status_reason': null,
              'applicable': true,
            },
          },
          'failed_agents': <String>[],
          'stalled_agents': <String>[],
        },
      );

      final results = await ws.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(results!.members.single.summary, 'LIVE 已落盘');
    });

    test('本轮只写了一部分成员时，重放补齐缺失成员', () async {
      const groupId = 'group_result_writer_replay';
      const orchId = 'orch-replay-partial';
      await ensureTask(groupId, orchId);
      final ws = GroupWorkspaceService.instance;

      // live 侧只落盘了 coder（例如另一个成员的写入被中断）。
      await ws.upsertTaskMemberResult(
        groupId: groupId,
        orchestrationId: orchId,
        memberResult: GroupTaskMemberResult(
          agentId: 'coder',
          agentName: 'Coder',
          round: 1,
          taskStatus: GroupTaskMemberResult.statusDone,
          summary: 'LIVE 已落盘',
        ),
      );

      await GroupResultWriter.persistFromMembersDonePayload(
        groupId: groupId,
        orchestrationId: orchId,
        agents: [_agent('coder', 'Coder'), _agent('doc', 'Doc')],
        payload: {
          'status': 'members_done',
          'round': 1,
          'orchestration_id': orchId,
          'member_results': {
            'coder': {
              'content': 'REPLAY coder\n[TASK_STATUS: done]',
              'task_status': 'done',
              'applicable': true,
            },
            'doc': {
              'content': 'REPLAY doc 文档已写\n[TASK_STATUS: done]',
              'task_status': 'done',
              'applicable': true,
            },
          },
          'failed_agents': <String>[],
          'stalled_agents': <String>[],
        },
      );

      final results = await ws.readTaskResults(
        groupId: groupId,
        orchestrationId: orchId,
      );
      final doc = results!.members
          .where((m) => m.agentId == 'doc')
          .firstOrNull;
      expect(doc, isNotNull,
          reason: '整轮判定会把缺失成员永久挡在重放之外，必须按成员判断');
      expect(doc!.summary, contains('REPLAY doc'));
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

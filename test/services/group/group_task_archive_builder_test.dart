import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_task_archive_builder.dart';
import 'package:shepaw/services/group/group_task_bootstrap.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  group('GroupTaskArchiveBuilder', () {
    test('builds full archive sections from task storage', () async {
      final ws = GroupWorkspaceService.instance;
      const groupId = 'group_archive_builder';
      const sessionId = 'session-archive';
      const orchId = 'orch-archive-1';

      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: sessionId,
        userGoal: '原始用户目标',
      );
      await ws.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: orchId,
        content: '# 定稿\n\n实现 PR-6 卷宗。',
      );
      await ws.writeTaskPlan(
        groupId: groupId,
        plan: GroupTaskPlan(
          orchestrationId: orchId,
          goal: '完成 archive 模板',
          steps: [
            GroupTaskPlanStep(
              step: 1,
              agents: ['Coder'],
              task: '写 builder',
            ),
          ],
        ),
      );
      await ws.writeRoundDispatch(
        groupId: groupId,
        sessionId: sessionId,
        round: 1,
        payload: {
          'status': 'dispatched',
          'round': 1,
          'orchestration_id': orchId,
          'steps': [
            {
              'step': 1,
              'agents': ['Coder'],
              'task': '写 builder',
              'mode': 'concurrent',
            },
          ],
        },
      );
      await ws.upsertTaskMemberResult(
        groupId: groupId,
        orchestrationId: orchId,
        memberResult: GroupTaskMemberResult(
          agentId: 'coder',
          agentName: 'Coder',
          round: 1,
          taskStatus: GroupTaskMemberResult.statusDone,
          summary: 'builder 已实现',
        ),
      );

      final task = (await ws.readTask(
        groupId: groupId,
        orchestrationId: orchId,
      ))!;

      final archive = await GroupTaskArchiveBuilder.build(
        ws: ws,
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: sessionId,
        task: task,
        finalSummary: '任务完成，卷宗已生成。',
        artifactUris: ['store://workspaces/dev/out.md'],
        rounds: 1,
      );

      expect(archive, contains('# 任务卷宗 $orchId'));
      expect(archive, contains('## 定稿需求'));
      expect(archive, contains('实现 PR-6 卷宗'));
      expect(archive, contains('## 计划'));
      expect(archive, contains('完成 archive 模板'));
      expect(archive, contains('## 执行摘要'));
      expect(archive, contains('第 1 轮派发'));
      expect(archive, contains('builder 已实现'));
      expect(archive, contains('## 最终结论'));
      expect(archive, contains('任务完成，卷宗已生成'));
      expect(archive, contains('## 产物'));
      expect(archive, contains('store://workspaces/dev/out.md'));
    });
  });

  group('GroupTaskBootstrap.onFinish', () {
    test('writes archive, final_summary_uri, and clears active index', () async {
      final ws = GroupWorkspaceService.instance;
      const groupId = 'group_finish_archive';
      const sessionId = 'session-finish';
      const orchId = 'orch-finish-1';

      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: sessionId,
        userGoal: 'Finish test',
      );
      await ws.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: orchId,
        content: '定稿 finish 测试',
      );

      const memoryUri = 'store://workspaces/dev/latest.md';
      await GroupTaskBootstrap.onFinish(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: sessionId,
        finalSummary: '全部完成。',
        artifactUris: const ['store://workspaces/dev/a.md'],
        finalSummaryUri: memoryUri,
        rounds: 1,
      );

      final task = await ws.readTask(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(task!.status, GroupTask.statusDone);
      expect(task.finalSummaryUri, memoryUri);
      expect(task.archiveUri, isNotNull);

      final archive = await ws.readTaskArchive(
        groupId: groupId,
        orchestrationId: orchId,
      );
      expect(archive, contains('## 计划'));
      expect(archive, contains('## 执行摘要'));
      expect(archive, contains('全部完成。'));

      final index = await ws.readTaskIndex(groupId);
      expect(index.activeOrchestrationId, isNull);
      expect(index.recent.first.orchestrationId, orchId);
      expect(index.recent.first.status, GroupTask.statusDone);
      expect(index.recent.first.finishedAt, isNotNull);
    });
  });

  group('GroupTaskBootstrap.sessionHandoffHint', () {
    test('returns hint when enough done tasks and messages', () async {
      final ws = GroupWorkspaceService.instance;
      const groupId = 'group_handoff_hint';

      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );

      for (var i = 0; i < 5; i++) {
        final id = 'done-$i';
        await ws.ensureTask(
          groupId: groupId,
          orchestrationId: id,
          sessionId: 'sess',
          userGoal: 'task $i',
        );
        await ws.updateTaskStatus(
          groupId: groupId,
          orchestrationId: id,
          status: GroupTask.statusDone,
        );
      }

      final hint = await GroupTaskBootstrap.sessionHandoffHint(
        groupId: groupId,
        channelMessageCount: 100,
      );

      expect(hint, isNotNull);
      expect(hint!, contains('group_session_create'));
      expect(hint, contains('noise_reduction'));
    });
  });
}

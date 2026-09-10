import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_task_bootstrap.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('publishPlan writes requirement and plan, task becomes planned', () async {
    final ws = GroupWorkspaceService.instance;
    await ws.ensureGroupWorkspace(
      groupId: 'group_plan_pub',
      members: [(agentId: 'admin', role: 'admin')],
    );

    const orchId = 'orch-plan-1';
    await ws.ensureTask(
      groupId: 'group_plan_pub',
      orchestrationId: orchId,
      sessionId: 'session-plan',
      userGoal: '原始用户消息',
    );

    final plan = GroupTaskPlan(
      orchestrationId: orchId,
      goal: '定稿：写设计文档',
      acceptanceCriteria: ['含架构图说明'],
      steps: [
        GroupTaskPlanStep(
          step: 1,
          agents: ['Coder'],
          task: '写文档',
        ),
      ],
    );

    final result = await GroupTaskBootstrap.publishPlan(
      groupId: 'group_plan_pub',
      orchestrationId: orchId,
      sessionId: 'session-plan',
      plan: plan,
      requirementText: '# 定稿需求\n\n写 PR-3 设计文档',
      requirementNotes: '用户已确认范围',
      issuedBy: 'admin',
    );

    expect(result.ok, isTrue, reason: result.error);
    expect(result.task!.status, GroupTask.statusPlanned);
    expect(result.task!.hasPublishedPlan, isTrue);

    final req = await ws.readTaskRequirement(
      groupId: 'group_plan_pub',
      orchestrationId: orchId,
    );
    expect(req, contains('PR-3'));

    final planJson = await ws.readTaskPlanJson(
      groupId: 'group_plan_pub',
      orchestrationId: orchId,
    );
    expect(planJson!.goal, '定稿：写设计文档');
  });

  group('GroupTaskBootstrap.onFinish terminal status', () {
    Future<void> ensureTask(String groupId, String orchId) async {
      final ws = GroupWorkspaceService.instance;
      await ws.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'session-finish',
        userGoal: '写文档',
      );
    }

    Future<GroupTask?> readBack(String groupId, String orchId) =>
        GroupWorkspaceService.instance.readTask(
          groupId: groupId,
          orchestrationId: orchId,
        );

    test('finish payload 携带 paused → 落盘 paused（不再冒充 done）', () async {
      const groupId = 'group_finish_paused';
      const orchId = 'orch-finish-paused';
      await ensureTask(groupId, orchId);

      await GroupTaskBootstrap.onFinish(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'session-finish',
        finalSummary: '向用户澄清后暂停',
        status: GroupTask.statusPaused,
      );

      final task = await readBack(groupId, orchId);
      expect(task!.status, GroupTask.statusPaused);
      expect(task.isTerminal, isTrue);
    });

    test('finish payload 携带 failed → 落盘 failed', () async {
      const groupId = 'group_finish_failed';
      const orchId = 'orch-finish-failed';
      await ensureTask(groupId, orchId);

      await GroupTaskBootstrap.onFinish(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'session-finish',
        finalSummary: '管理员总结失败',
        status: GroupTask.statusFailed,
      );

      final task = await readBack(groupId, orchId);
      expect(task!.status, GroupTask.statusFailed);
    });

    test('旧 payload / 未知状态回退到 done（兼容历史行为）', () async {
      const groupId = 'group_finish_legacy';
      const orchId = 'orch-finish-legacy';
      await ensureTask(groupId, orchId);

      // 无 status 字段（旧编排器 / 远端）→ done。
      await GroupTaskBootstrap.onFinish(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'session-finish',
        finalSummary: '完成',
      );

      final legacy = await readBack(groupId, orchId);
      expect(legacy!.status, GroupTask.statusDone);

      // 未知字符串同样回退 done，避免写坏终端态。
      const groupId2 = 'group_finish_unknown';
      const orchId2 = 'orch-finish-unknown';
      await ensureTask(groupId2, orchId2);
      await GroupTaskBootstrap.onFinish(
        groupId: groupId2,
        orchestrationId: orchId2,
        sessionId: 'session-finish',
        finalSummary: '完成',
        status: 'bogus',
      );

      final unknown = await readBack(groupId2, orchId2);
      expect(unknown!.status, GroupTask.statusPaused,
          reason: '未知终态不得冒充 done');
    });
  });
}

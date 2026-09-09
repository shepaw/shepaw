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
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_member_task_context.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_task_bootstrap.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('load prefers requirement.md and plan.md over user fallback', () async {
    GroupOrchestrationFeatures.structuredTasks = true;
    final ws = GroupWorkspaceService.instance;
    await ws.ensureGroupWorkspace(
      groupId: 'group_member_ctx',
      members: [(agentId: 'admin', role: 'admin')],
    );

    const orchId = 'orch-member-ctx';
    await ws.ensureTask(
      groupId: 'group_member_ctx',
      orchestrationId: orchId,
      sessionId: 'session-m',
      userGoal: '原始用户消息',
    );

    await GroupTaskBootstrap.publishPlan(
      groupId: 'group_member_ctx',
      orchestrationId: orchId,
      sessionId: 'session-m',
      plan: GroupTaskPlan(
        orchestrationId: orchId,
        goal: '定稿目标',
        acceptanceCriteria: ['含测试'],
        steps: [
          GroupTaskPlanStep(step: 1, agents: ['Coder'], task: '写代码'),
        ],
      ),
      requirementText: '# 定稿需求\n\n澄清后的 OpenAPI 文档需求',
      issuedBy: 'admin',
    );

    final ctx = await GroupMemberTaskContextLoader.load(
      groupId: 'group_member_ctx',
      orchestrationId: orchId,
      userMessageFallback: '原始用户消息 with bundle noise',
    );

    expect(ctx.globalRequirement, contains('OpenAPI 文档需求'));
    expect(ctx.globalRequirement, isNot(contains('bundle noise')));
    expect(ctx.taskPlanNote, contains('【正式任务计划】'));
    expect(ctx.taskPlanNote, contains('定稿目标'));
    expect(ctx.requirementUri, isNotNull);
    expect(ctx.planUri, isNotNull);
  });

  test('load falls back to user message when structured tasks disabled', () async {
    GroupOrchestrationFeatures.structuredTasks = false;
    addTearDown(() => GroupOrchestrationFeatures.structuredTasks = true);

    final ctx = await GroupMemberTaskContextLoader.load(
      groupId: 'missing',
      orchestrationId: 'missing',
      userMessageFallback: '仅 fallback',
    );
    expect(ctx.globalRequirement, '仅 fallback');
    expect(ctx.taskPlanNote, isEmpty);
  });
}

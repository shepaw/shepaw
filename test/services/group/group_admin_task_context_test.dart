import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_admin_task_context.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  group('GroupAdminTaskContextLoader', () {
    tearDown(() {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      GroupOrchestrationFeatures.structuredTasks = true;
      GroupOrchestrationFeatures.requirementUriOnlyPrompts = true;
    });

    test('buildCrossTaskNotes is empty when task scope disabled', () async {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.channel;

      final notes = await GroupAdminTaskContextLoader.buildCrossTaskNotes(
        groupId: 'group-x',
        orchestrationId: 'msg-1',
      );

      expect(notes, isEmpty);
    });

    test('includes previous task line and current requirement', () async {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      const groupId = 'group_admin_ctx';
      const prevId = 'prev-task';
      const currentId = 'current-task';

      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: prevId,
        sessionId: 'sess',
        userGoal: 'Build auth',
      );
      await GroupWorkspaceService.instance.updateTaskStatus(
        groupId: groupId,
        orchestrationId: prevId,
        status: GroupTask.statusDone,
      );
      await GroupWorkspaceService.instance.writeTaskArchive(
        groupId: groupId,
        orchestrationId: prevId,
        content: '# 任务卷宗\n\n## 最终结论\nShipped OAuth login.',
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: currentId,
        sessionId: 'sess',
        userGoal: 'Add billing',
      );
      await GroupWorkspaceService.instance.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: currentId,
        content: 'Integrate Stripe checkout.',
      );

      final notes = await GroupAdminTaskContextLoader.buildCrossTaskNotes(
        groupId: groupId,
        orchestrationId: currentId,
      );

      expect(notes, contains('[上一任务摘要]'));
      expect(notes, contains('Shipped OAuth login'));
      expect(notes, isNot(contains('Integrate Stripe checkout')));
    });

    test('includes inline requirement when uri-only prompts disabled', () async {
      GroupOrchestrationFeatures.requirementUriOnlyPrompts = false;
      const groupId = 'group_admin_ctx_inline';
      const currentId = 'current-inline';

      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: currentId,
        sessionId: 'sess',
        userGoal: 'Add billing',
      );
      await GroupWorkspaceService.instance.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: currentId,
        content: 'Integrate Stripe checkout.',
      );

      final notes = await GroupAdminTaskContextLoader.buildCrossTaskNotes(
        groupId: groupId,
        orchestrationId: currentId,
      );

      expect(notes, contains('[当前任务定稿需求（requirement.md）]'));
      expect(notes, contains('Integrate Stripe checkout'));
    });

    test('skips redundant requirement when it mirrors user message', () async {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      const groupId = 'group_admin_ctx_dedup';
      const currentId = 'current-dedup';

      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: currentId,
        sessionId: 'sess',
        userGoal: '排查外接 agent 链路',
      );
      await GroupWorkspaceService.instance.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: currentId,
        content: '排查外接 agent 链路',
      );

      final notes = await GroupAdminTaskContextLoader.buildCrossTaskNotes(
        groupId: groupId,
        orchestrationId: currentId,
        userMessageFallback: '排查外接 agent 链路',
      );

      expect(notes, isNot(contains('[当前任务定稿需求（requirement.md）]')));
    });

    test('buildMemberCrossTaskNote includes previous terminal task', () async {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      const groupId = 'group_member_ctx';
      const prevId = 'prev-m';
      const currentId = 'current-m';

      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin', role: 'admin')],
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: prevId,
        sessionId: 'sess',
        userGoal: 'Task A',
      );
      await GroupWorkspaceService.instance.updateTaskStatus(
        groupId: groupId,
        orchestrationId: prevId,
        status: GroupTask.statusDone,
      );
      await GroupWorkspaceService.instance.writeTaskArchive(
        groupId: groupId,
        orchestrationId: prevId,
        content: '# 卷宗\n\n## 最终结论\nDone task A summary.',
      );
      await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: currentId,
        sessionId: 'sess',
        userGoal: 'Task B',
      );

      final note = await GroupAdminTaskContextLoader.buildMemberCrossTaskNote(
        groupId: groupId,
        orchestrationId: currentId,
      );

      expect(note, contains('[上一任务摘要（截断）]'));
      expect(note, contains('Done task A'));
    });
  });
}

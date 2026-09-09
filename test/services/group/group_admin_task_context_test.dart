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
      expect(notes, contains('[当前任务定稿需求（requirement.md）]'));
      expect(notes, contains('Integrate Stripe checkout'));
    });
  });
}

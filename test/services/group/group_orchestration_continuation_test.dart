import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_orchestration_continuation.dart';
import 'package:shepaw/storage/group_workspace_service.dart';
import 'package:shepaw/storage/store_service.dart';

import '../../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  group('GroupOrchestrationContinuation', () {
    test('returns active non-terminal orchestration id', () async {
      const groupId = 'grp_cont';
      const orchId = 'msg-original';
      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin-1', role: 'admin')],
      );
      await GroupWorkspaceService.instance.createTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'sess-1',
        userGoal: '做一个登录页',
        status: GroupTask.statusClarifying,
      );

      final resolved =
          await GroupOrchestrationContinuation.resolveForInteractionResponse(
        groupId: groupId,
      );
      expect(resolved, orchId);
    });

    test('returns null when active task is terminal', () async {
      const groupId = 'grp_done';
      const orchId = 'msg-done';
      await GroupWorkspaceService.instance.ensureGroupWorkspace(
        groupId: groupId,
        members: [(agentId: 'admin-1', role: 'admin')],
      );
      await GroupWorkspaceService.instance.createTask(
        groupId: groupId,
        orchestrationId: orchId,
        sessionId: 'sess-1',
        userGoal: '已完成',
        status: GroupTask.statusDone,
      );

      final resolved =
          await GroupOrchestrationContinuation.resolveForInteractionResponse(
        groupId: groupId,
      );
      expect(resolved, isNull);
    });
  });
}

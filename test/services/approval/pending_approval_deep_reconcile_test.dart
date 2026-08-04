@Tags(['needs-plugins'])
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/planning_models.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/models/workflow_pending_approval.dart';
import 'package:shepaw/services/approval/pending_approval_hub.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/workflow/workflow_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 启动 hydrate 的全历史对账：脏 pending 行必须被治愈/关闭，
/// 只有仍存在未应答卡片的条目才保留横幅提醒。
/// Needs path_provider + sqflite harness; excluded from default CI via `needs-plugins`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '/tmp/shepaw_test');
  });

  setUp(() async {
    PendingApprovalHub.instance.resetForTest();
    final db = await LocalDatabaseService().database;
    await db.delete('workflow_executions');
    await db.delete('workflow_pending_approvals');
    await db.delete('messages');
  });

  tearDown(() {
    PendingApprovalHub.instance.resetForTest();
  });

  String uniqueId(String prefix) =>
      '$prefix-${DateTime.now().microsecondsSinceEpoch}';

  Future<WorkflowExecution> createWorkflow(String channelId) =>
      WorkflowService.instance.createWorkflowExecution(
        channelId: channelId,
        title: '测试工作流',
        flowPlan: FlowPlan(
          title: '测试工作流',
          summary: 's',
          stages: [
            FlowStage(
              stageId: 'st1',
              label: '阶段一',
              steps: [
                FlowStep(
                  stepId: 's1',
                  taskId: 't1',
                  agent: 'She',
                  instruction: 'do',
                ),
              ],
            ),
          ],
        ),
      );

  Future<void> backdateWorkflow(String workflowId, Duration age) async {
    final db = await LocalDatabaseService().database;
    await db.update(
      'workflow_executions',
      {'created_at': DateTime.now().subtract(age).millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [workflowId],
    );
  }

  Future<void> addPlanCard(
    String channelId,
    String workflowId, {
    bool? approved,
  }) =>
      LocalDatabaseService().createMessage(
        id: uniqueId('msg'),
        channelId: channelId,
        senderId: 'she',
        senderType: 'agent',
        senderName: 'She',
        content: 'plan',
        metadata: {
          'plan_approval': {
            '_workflowId': workflowId,
            'title': '测试工作流',
            if (approved != null) '_approved': approved,
          },
          if (approved != null)
            'plan_approval_responded': {'approved': approved},
        },
      );

  Future<WorkflowStatus?> workflowStatus(String workflowId) async =>
      (await WorkflowService.instance.getWorkflowExecutionWithSteps(workflowId))
          ?.status;

  group('hydrate deep reconcile', () {
    test('近期已批准的脏行：回补为 running（允许续跑）', () async {
      final channelId = uniqueId('ch');
      final exec = await createWorkflow(channelId);
      await addPlanCard(channelId, exec.id, approved: true);

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      expect(await workflowStatus(exec.id), WorkflowStatus.running);
    });

    test('超过重放窗口的已批准脏行：补记 completed，不复活执行', () async {
      final channelId = uniqueId('ch');
      final exec = await createWorkflow(channelId);
      await backdateWorkflow(exec.id, const Duration(hours: 48));
      await addPlanCard(channelId, exec.id, approved: true);

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      expect(await workflowStatus(exec.id), WorkflowStatus.completed);
    });

    test('已拒绝的脏行：回补为 cancelled', () async {
      final channelId = uniqueId('ch');
      final exec = await createWorkflow(channelId);
      await addPlanCard(channelId, exec.id, approved: false);

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      expect(await workflowStatus(exec.id), WorkflowStatus.cancelled);
    });

    test('存在未应答卡片：真待审，保留横幅提醒且不动工作流', () async {
      final channelId = uniqueId('ch');
      final exec = await createWorkflow(channelId);
      await addPlanCard(channelId, exec.id);

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, hasLength(1));
      expect(hub.all.first.id, 'plan:${exec.id}');
      expect(await workflowStatus(exec.id), WorkflowStatus.pendingApproval);
    });

    test('一张卡片都没有的孤儿行：直接取消归档，永不再弹', () async {
      final channelId = uniqueId('ch');
      final exec = await createWorkflow(channelId);

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      expect(await workflowStatus(exec.id), WorkflowStatus.cancelled);
    });

    test('action 脏行：已应答卡片 → 补记 submitted', () async {
      final channelId = uniqueId('ch');
      final confirmationId = uniqueId('cid');
      await WorkflowService.instance.savePendingApproval(
        WorkflowPendingApproval(
          id: uniqueId('pa'),
          workflowId: uniqueId('wf'),
          stepId: 's1',
          channelId: channelId,
          agentId: 'a1',
          agentName: 'Agent',
          peerId: 'peer-1',
          remoteAgentId: 'ra-1',
          confirmationId: confirmationId,
          peerSessionId: 'ps-1',
          approvalData: const {},
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await LocalDatabaseService().createMessage(
        id: uniqueId('msg'),
        channelId: channelId,
        senderId: 'a1',
        senderType: 'agent',
        senderName: 'Agent',
        content: 'confirm',
        metadata: {
          'action_confirmation': {
            'confirmation_id': confirmationId,
            'selected_action_id': 'allow',
          },
        },
      );

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      final record =
          await WorkflowService.instance.getPendingApprovalById(confirmationId);
      expect(record!.status, 'submitted');
    });

    test('action 孤儿行：无卡片 → 补记 submitted 关闭', () async {
      final channelId = uniqueId('ch');
      final confirmationId = uniqueId('cid');
      await WorkflowService.instance.savePendingApproval(
        WorkflowPendingApproval(
          id: uniqueId('pa'),
          workflowId: uniqueId('wf'),
          stepId: 's1',
          channelId: channelId,
          agentId: 'a1',
          agentName: 'Agent',
          peerId: 'peer-1',
          remoteAgentId: 'ra-1',
          confirmationId: confirmationId,
          peerSessionId: 'ps-1',
          approvalData: const {},
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

      final hub = PendingApprovalHub.instance..resetForTest();
      await hub.hydrate();

      expect(hub.all, isEmpty);
      final record =
          await WorkflowService.instance.getPendingApprovalById(confirmationId);
      expect(record!.status, 'submitted');
    });
  });
}

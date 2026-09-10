import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';

void main() {
  group('GroupTask', () {
    test('toJson/fromJson round-trip', () {
      final task = GroupTask(
        orchestrationId: 'msg-001',
        sessionId: 'channel-1',
        status: GroupTask.statusClarifying,
        userGoal: '帮我写一份 API 文档',
        createdAt: DateTime.parse('2026-09-09T10:00:00.000'),
        updatedAt: DateTime.parse('2026-09-09T10:01:00.000'),
      );
      final restored = GroupTask.fromJson(task.toJson());
      expect(restored, isNotNull);
      expect(restored!.orchestrationId, 'msg-001');
      expect(restored.sessionId, 'channel-1');
      expect(restored.status, GroupTask.statusClarifying);
      expect(restored.userGoal, '帮我写一份 API 文档');
      expect(restored.hasPublishedPlan, isFalse);
      expect(restored.isTerminal, isFalse);
    });

    test('hasPublishedPlan when planned with plan json uri', () {
      final task = GroupTask(
        orchestrationId: 'msg-002',
        sessionId: 'ch',
        status: GroupTask.statusPlanned,
        userGoal: 'goal',
        planJsonUri: 'store://workspaces/dev/group_x/shared/tasks/msg-002/plan.json',
      );
      expect(task.hasPublishedPlan, isTrue);
    });

    test('rejects invalid status', () {
      expect(
        GroupTask.fromJson({
          'orchestration_id': 'x',
          'session_id': 's',
          'status': 'unknown',
          'user_goal': 'g',
        }),
        isNull,
      );
    });
  });

  group('GroupTaskPlan', () {
    test('toJson/fromJson and toMarkdown', () {
      final plan = GroupTaskPlan(
        orchestrationId: 'msg-001',
        goal: '交付 REST API 文档',
        acceptanceCriteria: ['含鉴权章节', '含错误码表'],
        constraints: ['使用 Markdown'],
        steps: [
          GroupTaskPlanStep(
            step: 1,
            agents: ['Writer'],
            agentIds: ['agent-w'],
            task: '起草文档骨架',
            mode: 'concurrent',
          ),
        ],
        issuedBy: 'admin-1',
        issuedAt: DateTime.parse('2026-09-09T11:00:00.000'),
      );

      final restored = GroupTaskPlan.fromJson(plan.toJson());
      expect(restored, isNotNull);
      expect(restored!.goal, '交付 REST API 文档');
      expect(restored.steps.single.agents, ['Writer']);
      expect(restored.steps.single.mode, 'concurrent');

      final md = plan.toMarkdown(requirementNotes: '用户确认使用 OpenAPI 3.0');
      expect(md, contains('## 目标'));
      expect(md, contains('交付 REST API 文档'));
      expect(md, contains('## 验收标准'));
      expect(md, contains('含鉴权章节'));
      expect(md, contains('## 需求澄清摘要'));
      expect(md, contains('OpenAPI 3.0'));
      expect(md, contains('Writer'));
    });

    test('requires at least one step', () {
      expect(
        GroupTaskPlan.fromJson({
          'orchestration_id': 'x',
          'goal': 'g',
          'steps': [],
        }),
        isNull,
      );
    });
  });

  group('GroupTaskResults', () {
    test('upsertMember replaces same agent', () {
      final base = GroupTaskResults(orchestrationId: 'msg-1');
      final first = GroupTaskMemberResult(
        agentId: 'a1',
        agentName: 'Alice',
        taskStatus: GroupTaskMemberResult.statusPending,
        summary: '等待输入',
      );
      final second = GroupTaskMemberResult(
        agentId: 'a1',
        agentName: 'Alice',
        taskStatus: GroupTaskMemberResult.statusDone,
        summary: '已完成',
        artifactUris: ['store://workspaces/dev/f/out.md'],
      );

      final once = base.upsertMember(first);
      expect(once.members.length, 1);
      expect(once.members.single.taskStatus, GroupTaskMemberResult.statusPending);

      final twice = once.upsertMember(second);
      expect(twice.members.length, 1);
      expect(twice.members.single.taskStatus, GroupTaskMemberResult.statusDone);
      expect(twice.members.single.artifactUris.single, contains('out.md'));

      final restored = GroupTaskResults.fromJson(twice.toJson());
      expect(restored!.members.single.summary, '已完成');
    });

    test('upsertMember keeps per-round entries for the same agent', () {
      final base = GroupTaskResults(orchestrationId: 'msg-1');
      final round1 = GroupTaskMemberResult(
        agentId: 'a1',
        agentName: 'Alice',
        round: 1,
        taskStatus: GroupTaskMemberResult.statusDone,
        summary: '第一轮交付',
      );
      final round2 = GroupTaskMemberResult(
        agentId: 'a1',
        agentName: 'Alice',
        round: 2,
        taskStatus: GroupTaskMemberResult.statusDone,
        summary: '第二轮交付',
      );

      final once = base.upsertMember(round1);
      final twice = once.upsertMember(round2);

      expect(twice.members.length, 2);
      expect(twice.members.map((m) => m.round), containsAll([1, 2]));

      // 同 (agent, round) 仍是替换而非追加。
      final round2Again = GroupTaskMemberResult(
        agentId: 'a1',
        agentName: 'Alice',
        round: 2,
        taskStatus: GroupTaskMemberResult.statusFailed,
        summary: '第二轮重试失败',
      );
      final thrice = twice.upsertMember(round2Again);
      expect(thrice.members.length, 2);
      expect(
        thrice.members.singleWhere((m) => m.round == 2).taskStatus,
        GroupTaskMemberResult.statusFailed,
      );

      final restored = GroupTaskResults.fromJson(thrice.toJson());
      expect(restored!.members.length, 2);
    });
  });

  group('GroupTaskIndex', () {
    test('withActiveTask sets active id and prepends recent', () {
      final index = GroupTaskIndex(
        activeOrchestrationId: 'old',
        recent: [
          GroupTaskIndexEntry(
            orchestrationId: 'old',
            status: GroupTask.statusExecuting,
            title: '旧任务',
          ),
        ],
      );
      final task = GroupTask(
        orchestrationId: 'new-msg',
        sessionId: 'ch',
        status: GroupTask.statusClarifying,
        userGoal: '新任务：修复登录 bug',
      );
      final updated = index.withActiveTask(task);
      expect(updated.activeOrchestrationId, 'new-msg');
      expect(updated.recent.first.orchestrationId, 'new-msg');
      expect(updated.recent.first.title, contains('修复登录'));
      expect(updated.recent.length, 2);
    });

    test('terminal task clears active orchestration id', () {
      final task = GroupTask(
        orchestrationId: 'done-msg',
        sessionId: 'ch',
        status: GroupTask.statusDone,
        userGoal: '已完成',
        finishedAt: DateTime.parse('2026-09-09T12:00:00.000'),
      );
      final updated =
          GroupTaskIndex(activeOrchestrationId: 'done-msg').withActiveTask(task);
      expect(updated.activeOrchestrationId, isNull);
      expect(updated.recent.first.status, GroupTask.statusDone);
    });
  });
}

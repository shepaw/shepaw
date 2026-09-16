import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';

void main() {
  group('GroupDispatchParser buildMemberTurnContent / buildTaskPlanNote', () {
    test('injects formal task plan between global and local task', () {
      final content = GroupDispatchParser.buildMemberTurnContent(
        memberBrief: '实现登录',
        globalRequirement: '# 定稿需求\n\n用户要 OpenAPI 文档',
        memoryNote: '',
        taskPlanNote: GroupDispatchParser.buildTaskPlanNote(
          body: '## 目标\n交付 OpenAPI 3 文档',
          planUri: 'store://workspaces/dev/group_x/shared/tasks/msg/plan.md',
        ),
      );
      expect(content, contains('【全局需求】'));
      expect(content, contains('OpenAPI 文档'));
      expect(content, contains('【正式任务计划】'));
      expect(content, contains('store://'));
      expect(content, contains('【你的任务】'));
      expect(content, contains('实现登录'));
      final globalIdx = content.indexOf('【全局需求】');
      final planIdx = content.indexOf('【正式任务计划】');
      final taskIdx = content.indexOf('【你的任务】');
      expect(globalIdx, lessThan(planIdx));
      expect(planIdx, lessThan(taskIdx));
    });

    test('appends peer results note (PR-7)', () {
      final content = GroupDispatchParser.buildMemberTurnContent(
        memberBrief: '写测试',
        globalRequirement: '交付功能',
        memoryNote: '',
        peerResultsNote: '【同轮完成情况】\n- Coder (done): API 已实现',
      );
      expect(content, contains('【同轮完成情况】'));
      expect(content, contains('Coder (done)'));
      expect(content, contains('【你的任务】'));
    });

    test('first round omits global body when uri-only prompts enabled', () {
      GroupOrchestrationFeatures.requirementUriOnlyPrompts = true;
      final content = GroupDispatchParser.buildMemberTurnContent(
        memberBrief: '做 recon 探测',
        globalRequirement: '（定稿需求见 `store://workspaces/dev/tasks/o1/requirement.md`，请 store read 后执行）',
        memoryNote: '',
        requirementUri: 'store://workspaces/dev/tasks/o1/requirement.md',
        isFollowUpRound: false,
      );
      expect(content, contains('【你的任务】'));
      expect(content, contains('做 recon 探测'));
      expect(content, contains('requirement.md'));
      expect(content, isNot(contains('【全局需求】')));
    });

    test('follow-up round omits repeated global requirement', () {
      final content = GroupDispatchParser.buildMemberTurnContent(
        memberBrief: '补交 app-recon 摘要',
        globalRequirement: '用户完整需求原文很长很长',
        memoryNote: '',
        requirementUri: 'store://workspaces/dev/shared/tasks/o1/requirement.md',
        isFollowUpRound: true,
      );
      expect(content, contains('【你的任务】'));
      expect(content, contains('补交 app-recon 摘要'));
      expect(content, contains('requirement.md'));
      expect(content, isNot(contains('【全局需求】')));
      expect(content, isNot(contains('用户完整需求原文很长很长')));
    });

    test('follow-up round skips global even when brief equals global text', () {
      const global = '用户完整需求原文很长很长';
      final content = GroupDispatchParser.buildMemberTurnContent(
        memberBrief: global,
        globalRequirement: global,
        memoryNote: '',
        requirementUri: 'store://workspaces/dev/shared/tasks/o1/requirement.md',
        isFollowUpRound: true,
      );
      expect(content, contains('【你的任务】'));
      expect(content, contains('requirement.md'));
      expect(content, isNot(contains('【全局需求】')));
      // Brief may repeat goal text; full global block must not appear twice.
      expect(content.indexOf('【全局需求】'), -1);
    });

    test('truncates long plan bodies', () {
      final note = GroupDispatchParser.buildTaskPlanNote(
        body: 'x' * 50,
        maxChars: 10,
      );
      expect(note, contains('【正式任务计划】'));
      expect(note.endsWith('…'), isTrue);
    });
  });
}

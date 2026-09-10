import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_dispatch_parser.dart';

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

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_admin_context_budget.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';

void main() {
  group('GroupAdminContextBudget', () {
    tearDown(() {
      GroupOrchestrationFeatures.adminContextBudgetChars = 12000;
    });

    test('uses full mode when under budget', () {
      GroupOrchestrationFeatures.adminContextBudgetChars = 10000;
      final content = GroupAdminContextBudget.assembleLoopSummarizeContent(
        adminSummarizeBase: 'base',
        lastDispatchNote: 'step1→A',
        dispatchUri: 'store://workspaces/d/g/round-0001/dispatch.json',
        memberArtifactsBlock: '',
        structuredResultsBlock: '\n\n【结构化成员结果】\n- A (done): ok',
        structuredResultsCompactBlock: '\n\n【成员结果摘要】\n- A (done): ok',
        summarizeArtifactNotes: '',
        summarizeArtifactCompactNotes: '',
        pendingNote: '',
        sessionHandoffSuffix: '',
        artifactPrefillBlock: '\n\n【成员产物摘录】\n  body',
      );
      expect(content, contains('你上一轮的派发记录'));
      expect(content, contains('【成员产物摘录】'));
      expect(content, contains('step1→A'));
      expect(content, isNot(contains('摘要模式')));
    });

    test('assembleFirstAdminTurnContent compacts when over budget', () {
      GroupOrchestrationFeatures.adminContextBudgetChars = 500;
      final longMemory = 'm' * 2000;
      final out = GroupAdminContextBudget.assembleFirstAdminTurnContent(
        bundledContent: '用户：排查外接 agent\n\n## 当前储物袋作用域\n' + ('x' * 3000),
        groupMemoryBlock:
            '[群历史任务总结（shared/memory/latest.md）]\n$longMemory',
        groupMemoryUri: 'store://workspaces/d/g/shared/memory/latest.md',
        crossTaskNotes: '[上一任务摘要]\nDone.\n\n[当前任务定稿需求（requirement.md）]\nReq',
        artifactNotes: '\n\n【已登记产物】\n- big plan block',
        artifactCompactNotes: '\n\n【产物链接】\n- store://a',
        requirementUri: 'store://workspaces/d/tasks/o1/requirement.md',
        userGoal: '排查外接 agent',
      );
      expect(out.length, lessThanOrEqualTo(500));
      expect(out, anyOf(contains('摘要模式'), contains('本轮续编')));
    });

    test('assembleFirstAdminTurnContent keeps full stack under budget', () {
      GroupOrchestrationFeatures.adminContextBudgetChars = 50000;
      const bundled = '用户目标\n\n## Scope';
      final out = GroupAdminContextBudget.assembleFirstAdminTurnContent(
        bundledContent: bundled,
        groupMemoryBlock: '',
        crossTaskNotes: '',
        artifactNotes: '',
        artifactCompactNotes: '',
        userGoal: '用户目标',
      );
      expect(out, bundled);
    });

    test('buildNudgeContent uses short prefix not full effectiveContent stack', () {
      GroupOrchestrationFeatures.adminContextBudgetChars = 10000;
      final nudge = GroupAdminContextBudget.buildNudgeContent(
        adminSummarizeBase: '【本轮续编 · 第 2 轮】定稿需求 `store://req`。',
        systemNote: '[SYSTEM] 请重新 group_dispatch',
      );
      expect(nudge, contains('【本轮续编'));
      expect(nudge, contains('[SYSTEM]'));
      expect(nudge, isNot(contains('当前储物袋作用域')));
    });

    test('switches to compact mode when over budget', () {
      GroupOrchestrationFeatures.adminContextBudgetChars = 200;
      final longDispatch = 'x' * 500;
      final content = GroupAdminContextBudget.assembleLoopSummarizeContent(
        adminSummarizeBase: 'base',
        lastDispatchNote: longDispatch,
        dispatchUri: 'store://workspaces/dev/group/s/round-0001/dispatch.json',
        memberArtifactsBlock: '',
        structuredResultsBlock: '\n\n【结构化】\n${'y' * 300}',
        structuredResultsCompactBlock: '\n\n【摘要】\n- A (done): short',
        summarizeArtifactNotes: '',
        summarizeArtifactCompactNotes: '\n\n【产物链接】\n- store://a',
        pendingNote: '',
        sessionHandoffSuffix: '',
        resultsUri: 'store://workspaces/dev/results.json',
      );
      expect(content, contains('摘要模式'));
      expect(content, contains('dispatch.json'));
      expect(content, isNot(contains(longDispatch)));
    });
  });
}

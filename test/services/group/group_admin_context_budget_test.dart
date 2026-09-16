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

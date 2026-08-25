import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/workflow_models.dart';

/// StepExecutionStatus / WorkflowExecution 状态语义（M11：取消 ≠ 失败）。
void main() {
  group('StepExecutionStatus', () {
    test('fromDb round-trips cancelled; unknown falls back to pending', () {
      expect(StepExecutionStatus.fromDb('cancelled'),
          StepExecutionStatus.cancelled);
      expect(StepExecutionStatus.cancelled.dbValue, 'cancelled');
      expect(StepExecutionStatus.fromDb(null), StepExecutionStatus.pending);
      expect(StepExecutionStatus.fromDb('bogus'), StepExecutionStatus.pending);
    });
  });

  group('WorkflowExecution step aggregates', () {
    WorkflowExecution execution(List<WorkflowStepExecution> steps) =>
        WorkflowExecution(
          id: 'w',
          channelId: 'c',
          title: 't',
          flowPlanJson: '{"stages":[]}',
          createdAt: DateTime(2026),
          steps: steps,
        );

    WorkflowStepExecution step(StepExecutionStatus s, int i) =>
        WorkflowStepExecution(
          id: 's$i',
          workflowExecutionId: 'w',
          stageIndex: 0,
          stepIndex: i,
          agentName: 'A',
          instruction: 'do',
          status: s,
        );

    test('cancelled steps are terminal but neither failed nor succeeded', () {
      final e = execution([
        step(StepExecutionStatus.cancelled, 0),
        step(StepExecutionStatus.skipped, 1),
      ]);
      expect(e.allStepsTerminal, isTrue);
      expect(e.failedSteps, 0);
      expect(e.allStepsSucceeded, isFalse);
      // skipped 计入 completedSteps 口径；cancelled 不计入。
      expect(e.completedSteps, 1);
    });
  });
}

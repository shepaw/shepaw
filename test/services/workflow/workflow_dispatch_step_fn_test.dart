import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/workflow/workflow_dispatch_command.dart';

void main() {
  tearDown(() => WorkflowDispatchCommand.executeStepFnMap.clear());

  group('M9 executeStepFn per-channel lifecycle', () {
    test('set then clear removes the callback', () {
      WorkflowDispatchCommand.setExecuteStepFn('ch-1', (a, i, c) async => 'ok');
      expect(WorkflowDispatchCommand.executeStepFnMap, contains('ch-1'));

      WorkflowDispatchCommand.clearExecuteStepFn('ch-1');
      expect(WorkflowDispatchCommand.executeStepFnMap, isNot(contains('ch-1')));
    });

    test('clearing one channel leaves other channels intact', () {
      WorkflowDispatchCommand.setExecuteStepFn('ch-1', (a, i, c) async => 'a');
      WorkflowDispatchCommand.setExecuteStepFn('ch-2', (a, i, c) async => 'b');

      WorkflowDispatchCommand.clearExecuteStepFn('ch-1');

      expect(WorkflowDispatchCommand.executeStepFnMap, isNot(contains('ch-1')));
      expect(WorkflowDispatchCommand.executeStepFnMap, contains('ch-2'));
    });

    test('re-registering replaces the stale closure for the same channel',
        () async {
      WorkflowDispatchCommand.setExecuteStepFn('ch-1', (a, i, c) async => 'old');
      // A later turn re-registers — the stale closure must be replaced, not
      // appended or kept alongside.
      WorkflowDispatchCommand.setExecuteStepFn('ch-1', (a, i, c) async => 'new');

      expect(WorkflowDispatchCommand.executeStepFnMap, hasLength(1));
      expect(
        await WorkflowDispatchCommand.executeStepFnMap['ch-1']!(
            'a', 'i', 'ch-1'),
        'new',
      );
    });

    test('clear on a channel that was never registered is a no-op', () {
      WorkflowDispatchCommand.clearExecuteStepFn('never-registered');
      expect(WorkflowDispatchCommand.executeStepFnMap, isEmpty);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/services/group/group_task_workflow_matcher.dart';

GroupTask _task({
  required String id,
  required String sessionId,
  required DateTime createdAt,
  DateTime? finishedAt,
}) {
  return GroupTask(
    orchestrationId: id,
    sessionId: sessionId,
    status: finishedAt == null
        ? GroupTask.statusExecuting
        : GroupTask.statusDone,
    userGoal: id,
    createdAt: createdAt,
    updatedAt: createdAt,
    finishedAt: finishedAt,
  );
}

WorkflowExecution _wf({
  required String id,
  required String channelId,
  required DateTime createdAt,
}) {
  return WorkflowExecution(
    id: id,
    channelId: channelId,
    title: id,
    flowPlanJson: '{}',
    createdAt: createdAt,
  );
}

void main() {
  test('single session task takes every workflow on that channel', () {
    final task = _task(
      id: 't1',
      sessionId: 'ch',
      createdAt: DateTime(2026, 1, 1),
    );
    final wf = _wf(
      id: 'w1',
      channelId: 'ch',
      createdAt: DateTime(2026, 6, 1),
    );
    final assigned = GroupTaskWorkflowMatcher.assign(
      tasks: [task],
      workflows: [wf],
    );
    expect(assigned.forTask('t1').map((e) => e.id), ['w1']);
    expect(assigned.orphans, isEmpty);
  });

  test('overlapping window maps workflow to the nearer task', () {
    final early = _task(
      id: 'early',
      sessionId: 'ch',
      createdAt: DateTime(2026, 1, 1, 10),
      finishedAt: DateTime(2026, 1, 1, 11),
    );
    final late = _task(
      id: 'late',
      sessionId: 'ch',
      createdAt: DateTime(2026, 1, 1, 12),
    );
    final wf = _wf(
      id: 'w-late',
      channelId: 'ch',
      createdAt: DateTime(2026, 1, 1, 12, 5),
    );
    final assigned = GroupTaskWorkflowMatcher.assign(
      tasks: [early, late],
      workflows: [wf],
    );
    expect(assigned.forTask('late').map((e) => e.id), ['w-late']);
    expect(assigned.forTask('early'), isEmpty);
    expect(assigned.orphans, isEmpty);
  });

  test('other-channel workflow is an orphan', () {
    final task = _task(
      id: 't1',
      sessionId: 'ch-a',
      createdAt: DateTime(2026, 1, 1),
    );
    final wf = _wf(
      id: 'w1',
      channelId: 'ch-b',
      createdAt: DateTime(2026, 1, 1, 0, 1),
    );
    final assigned = GroupTaskWorkflowMatcher.assign(
      tasks: [task],
      workflows: [wf],
    );
    expect(assigned.forTask('t1'), isEmpty);
    expect(assigned.orphans.map((e) => e.id), ['w1']);
  });
}

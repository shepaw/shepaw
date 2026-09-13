import '../../models/group_task.dart';
import '../../models/workflow_models.dart';

/// Assigns channel workflows to [GroupTask]s (same session + overlapping time).
class GroupTaskWorkflowAssignment {
  const GroupTaskWorkflowAssignment({
    required this.byOrchestrationId,
    required this.orphans,
  });

  final Map<String, List<WorkflowExecution>> byOrchestrationId;
  final List<WorkflowExecution> orphans;

  List<WorkflowExecution> forTask(String orchestrationId) =>
      byOrchestrationId[orchestrationId] ?? const [];
}

class GroupTaskWorkflowMatcher {
  GroupTaskWorkflowMatcher._();

  static const overlapPad = Duration(minutes: 2);

  static GroupTaskWorkflowAssignment assign({
    required List<GroupTask> tasks,
    required List<WorkflowExecution> workflows,
  }) {
    final byId = <String, List<WorkflowExecution>>{
      for (final task in tasks) task.orchestrationId: <WorkflowExecution>[],
    };
    final orphans = <WorkflowExecution>[];

    for (final workflow in workflows) {
      final match = _bestTask(tasks, workflow);
      if (match == null) {
        orphans.add(workflow);
      } else {
        byId[match.orchestrationId]!.add(workflow);
      }
    }
    return GroupTaskWorkflowAssignment(
      byOrchestrationId: byId,
      orphans: orphans,
    );
  }

  static GroupTask? _bestTask(
    List<GroupTask> tasks,
    WorkflowExecution workflow,
  ) {
    final sameSession =
        tasks.where((t) => t.sessionId == workflow.channelId).toList();
    if (sameSession.isEmpty) return null;
    if (sameSession.length == 1) return sameSession.first;

    GroupTask? best;
    var bestDelta = 1 << 30;
    for (final task in sameSession) {
      final start = task.createdAt.subtract(overlapPad);
      final end = (task.finishedAt ?? DateTime.now()).add(overlapPad);
      if (workflow.createdAt.isBefore(start) ||
          workflow.createdAt.isAfter(end)) {
        continue;
      }
      final delta =
          workflow.createdAt.difference(task.createdAt).inMilliseconds.abs();
      if (best == null || delta < bestDelta) {
        best = task;
        bestDelta = delta;
      }
    }
    return best;
  }
}

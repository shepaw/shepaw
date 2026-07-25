import '../../models/remote_agent.dart';
import '../../models/workflow_models.dart';
import '../she_service.dart';

/// Resolve which [RemoteAgent] should run a workflow step, and how to
/// schedule steps within a DM workflow stage.
class WorkflowStepAgentResolver {
  WorkflowStepAgentResolver._();

  /// Find [agentName] first in [channelAgents], then in [allAgents]
  /// (exact name match). Returns null when unresolved.
  static RemoteAgent? resolve({
    required String agentName,
    required List<RemoteAgent> channelAgents,
    required List<RemoteAgent> allAgents,
  }) {
    if (agentName.isEmpty) return null;

    for (final a in channelAgents) {
      if (a.name == agentName) return a;
    }
    for (final a in allAgents) {
      if (a.name == agentName) return a;
    }
    return null;
  }

  /// Whether this agent runs on the She DM channel itself (not a relay).
  static bool runsOnSheChannel(RemoteAgent agent) =>
      agent.id == SheService.sheId || SheService.isSheIdentity(agent.id, agent.metadata);

  /// Group [steps] by [WorkflowStepExecution.agentName], preserving
  /// first-seen agent order and step order within each group.
  ///
  /// Callers run groups concurrently ([Future.wait]) while executing
  /// each group's steps serially — same agent shares one channel /
  /// `_activeTasks` key and must not overlap.
  static List<List<T>> groupByAgentName<T>(
    Iterable<T> steps,
    String Function(T step) agentNameOf,
  ) {
    final order = <String>[];
    final map = <String, List<T>>{};
    for (final step in steps) {
      final name = agentNameOf(step);
      if (!map.containsKey(name)) {
        order.add(name);
        map[name] = <T>[];
      }
      map[name]!.add(step);
    }
    return [for (final name in order) map[name]!];
  }

  /// Convenience over [groupByAgentName] for [WorkflowStepExecution].
  static List<List<WorkflowStepExecution>> groupStepExecutions(
    Iterable<WorkflowStepExecution> steps,
  ) =>
      groupByAgentName(steps, (s) => s.agentName);
}

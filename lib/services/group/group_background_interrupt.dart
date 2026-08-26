import '../task/task_models.dart';

/// Pure helper: which group channels have in-flight ACP tasks whose
/// connection is currently down (same trigger as 1:1 `handleAppResumed`).
class GroupBackgroundInterrupt {
  GroupBackgroundInterrupt._();

  /// Channel ids that should be treated as interrupted after a background
  /// resume. Local / peer members (no ACP connection) are ignored — they
  /// keep running, matching the 1:1 local-LLM policy.
  static List<String> deadAcpChannelIds({
    required Map<String, Map<String, GroupActiveTask>> activeGroupTasks,
    required bool Function(String agentId) hasAcpConnection,
    required bool Function(String agentId) isConnected,
  }) {
    final out = <String>[];
    for (final e in activeGroupTasks.entries) {
      for (final task in e.value.values) {
        if (task.isComplete) continue;
        if (!hasAcpConnection(task.agentId)) continue;
        if (!isConnected(task.agentId)) {
          out.add(e.key);
          break;
        }
      }
    }
    return out;
  }
}

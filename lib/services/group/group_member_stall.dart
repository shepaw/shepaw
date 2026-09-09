import '../acp_agent_connection.dart';
import '../logger_service.dart';
import '../../models/remote_agent.dart';
import 'group_orchestration_features.dart';
import 'group_turn_result.dart';

/// Member execution timed out (ACP task wait) — not a hard infrastructure failure.
class MemberStalledException implements Exception {
  MemberStalledException({
    required this.agentName,
    this.timeout = acpTaskTimeout,
  });

  final String agentName;
  final Duration timeout;

  @override
  String toString() =>
      'MemberStalledException: $agentName stalled after ${timeout.inSeconds}s';
}

/// Tracks per-member stall counts within one orchestration session.
class GroupMemberStallTracker {
  final Map<String, int> _countsByAgentName = {};

  int countFor(String agentName) => _countsByAgentName[agentName] ?? 0;

  /// Increment stall count. Returns `true` when escalated to failed.
  bool recordStall({
    required String agentName,
    required List<String> failedAgentNames,
    required List<String> stalledAgentNames,
  }) {
    final next = countFor(agentName) + 1;
    _countsByAgentName[agentName] = next;
    if (next >= GroupOrchestrationFeatures.maxStallsBeforeFail) {
      stalledAgentNames.remove(agentName);
      if (!failedAgentNames.contains(agentName)) {
        failedAgentNames.add(agentName);
      }
      return true;
    }
    if (!stalledAgentNames.contains(agentName)) {
      stalledAgentNames.add(agentName);
    }
    return false;
  }

  static List<MemberStallRequest> buildRequests({
    required List<String> stalledAgentNames,
    required List<RemoteAgent> agents,
    required GroupMemberStallTracker tracker,
    Duration timeout = acpTaskTimeout,
  }) {
    final byName = {for (final a in agents) a.name: a};
    return [
      for (final name in stalledAgentNames)
        if (byName[name] != null)
          MemberStallRequest(
            agentId: byName[name]!.id,
            name: name,
            timeout: timeout,
            stallCount: tracker.countFor(name),
          ),
    ];
  }
}

class MemberStallRequest {
  const MemberStallRequest({
    required this.agentId,
    required this.name,
    required this.timeout,
    required this.stallCount,
  });

  final String agentId;
  final String name;
  final Duration timeout;
  final int stallCount;
}

/// Shared catchError handler for member turns (loop + cascade).
class GroupMemberStallHandler {
  GroupMemberStallHandler._();

  static GroupTurnResult handleExecutionError({
    required Object error,
    required RemoteAgent agent,
    GroupMemberStallTracker? tracker,
    List<String>? failedAgentNames,
    List<String>? stalledAgentNames,
    void Function(String agentId, String agentName, bool skipped)? onAgentDone,
    String logLabel = 'agent',
  }) {
    if (GroupOrchestrationFeatures.stalledTimeout &&
        error is MemberStalledException &&
        tracker != null &&
        failedAgentNames != null &&
        stalledAgentNames != null) {
      final escalated = tracker.recordStall(
        agentName: agent.name,
        failedAgentNames: failedAgentNames,
        stalledAgentNames: stalledAgentNames,
      );
      LoggerService().warning(
        escalated
            ? 'Member ${agent.name} escalated to failed after repeated stalls'
            : 'Member ${agent.name} stalled (timeout ${error.timeout.inSeconds}s)',
        tag: 'GroupOrchestrationService',
      );
      onAgentDone?.call(agent.id, agent.name, true);
      return const GroupTurnResult();
    }

    LoggerService().error(
      'Delegated $logLabel ${agent.name} uncaught error',
      tag: 'GroupOrchestrationService',
      error: error,
    );
    failedAgentNames?.add(agent.name);
    onAgentDone?.call(agent.id, agent.name, true);
    return const GroupTurnResult();
  }
}

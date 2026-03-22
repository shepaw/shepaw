import 'dart:async';

/// Holds a pending plan_approval waiting for user response.
/// Survives channel navigation — the Completer stays alive until
/// the user submits or the orchestration is explicitly cancelled.
class PlanApprovalHandle {
  final String channelId;
  final String agentId;
  final String agentName;
  final Map<String, dynamic> planData;
  final String messageId;
  final Completer<Map<String, dynamic>?> completer;

  PlanApprovalHandle({
    required this.channelId,
    required this.agentId,
    required this.agentName,
    required this.planData,
    required this.messageId,
    required this.completer,
  });
}

/// Manages pending plan approvals, keyed by channelId.
/// At most one pending approval per channel.
class PlanApprovalService {
  final Map<String, PlanApprovalHandle> _pendingApprovals = {};

  /// Register a pending plan approval for [channelId].
  /// Any stale handle for the same channel is cancelled first.
  Future<Map<String, dynamic>?> awaitPlanApproval({
    required String channelId,
    required String agentId,
    required String agentName,
    required Map<String, dynamic> planData,
    required String messageId,
  }) {
    // Cancel any stale handle for the same channel
    final stale = _pendingApprovals[channelId];
    if (stale != null && !stale.completer.isCompleted) {
      stale.completer.complete(null);
    }
    final handle = PlanApprovalHandle(
      channelId: channelId,
      agentId: agentId,
      agentName: agentName,
      planData: planData,
      messageId: messageId,
      completer: Completer(),
    );
    _pendingApprovals[channelId] = handle;
    return handle.completer.future;
  }

  /// Returns the pending plan_approval handle for [channelId], or null.
  PlanApprovalHandle? getPendingPlanApproval(String channelId) =>
      _pendingApprovals[channelId];

  /// Submit user's plan approval result (approve/reject/feedback).
  void completePlanApproval(String channelId, Map<String, dynamic> result) {
    final handle = _pendingApprovals.remove(channelId);
    if (handle != null && !handle.completer.isCompleted) {
      handle.completer.complete(result);
    }
  }

  /// Cancel pending plan_approval for [channelId] (e.g. user explicitly stops).
  void cancelPlanApproval(String channelId) {
    final handle = _pendingApprovals.remove(channelId);
    if (handle != null && !handle.completer.isCompleted) {
      handle.completer.complete(null);
    }
  }
}

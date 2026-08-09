/// Thrown when the user taps a peer approval card that is no longer tracked
/// locally (turn finished / timed out / already submitted / app restarted
/// without a hub replay). Callers must keep the UI selection and persist it —
/// rolling back would revive a dead "pending" card on the next reload.
class PeerApprovalExpiredException implements Exception {
  final String message;

  const PeerApprovalExpiredException([
    this.message = '审批已失效（对话已结束或结果已提交），无需重复操作',
  ]);

  @override
  String toString() => message;

  /// Whether [error] (or nested causes) is an expired peer-approval verdict.
  static bool matches(Object? error) {
    if (error is PeerApprovalExpiredException) return true;
    final text = error?.toString() ?? '';
    return text.contains('审批已失效');
  }
}

/// Pure helpers for peer tool-approval hub payloads.
///
/// Kept free of [PeerAgentClientService] / connection state so openApprovals
/// gating contracts can be unit-tested without plugins.
class PeerApprovalPayload {
  PeerApprovalPayload._();

  /// Hub sometimes omits [approvalId]; synthesize a stable id from [requestId].
  static String normalizeApprovalId(String? approvalId, String requestId) {
    if (approvalId == null || approvalId.isEmpty) {
      return 'missing_$requestId';
    }
    return approvalId;
  }

  /// Default Allow/Deny pair when the hub/agent omits actions.
  static List<dynamic> effectiveActions(List<dynamic>? raw) {
    if (raw != null && raw.isNotEmpty) {
      return List<dynamic>.from(raw);
    }
    return const [
      {'id': 'allow', 'label': 'Allow', 'style': 'primary'},
      {'id': 'deny', 'label': 'Deny', 'style': 'danger'},
    ];
  }

  /// Map hub `agent_approval_req` fields into the chat action-confirmation card.
  static Map<String, dynamic> buildActionConfirmationData({
    required Map<String, dynamic> data,
    required String approvalId,
    required List<dynamic> actions,
  }) {
    return <String, dynamic>{
      'confirmation_id': approvalId,
      'prompt': data['prompt'] ?? '',
      'actions': actions,
      'confirmation_context': 'peer',
      if (data['tool_kind'] != null) 'tool_kind': data['tool_kind'],
      if (data['tool_call_id'] != null) 'tool_call_id': data['tool_call_id'],
    };
  }
}

/// Tracks whether `agent_done` must wait for outstanding tool approvals.
///
/// Mirrors the openApprovals gate inside [PeerAgentClientService] so the
/// increment / buffer / release rules can be tested in isolation.
class PeerApprovalTurnGate {
  int openApprovals = 0;
  Map<String, dynamic>? bufferedDone;

  void onApprovalOpened() => openApprovals++;

  /// Returns false if there was nothing to decrement (already at zero).
  bool onApprovalResolved() {
    if (openApprovals <= 0) return false;
    openApprovals--;
    return true;
  }

  /// Buffer [donePayload] when approvals are still open; otherwise ready now.
  bool bufferDoneIfApprovalsOpen(Map<String, dynamic> donePayload) {
    if (openApprovals > 0) {
      bufferedDone = donePayload;
      return true;
    }
    bufferedDone = null;
    return false;
  }

  /// Pop buffered done when the gate is clear; null if still blocked or empty.
  Map<String, dynamic>? tryCompleteBufferedDone() {
    if (openApprovals > 0 || bufferedDone == null) return null;
    final payload = bufferedDone;
    bufferedDone = null;
    return payload;
  }
}

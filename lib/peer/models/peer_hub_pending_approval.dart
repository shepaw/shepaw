import 'dart:convert';

/// Hub-side persisted peer tool approval awaiting a delayed client response.
class PeerHubPendingApproval {
  final String approvalId;
  final String peerId;
  final String requestId;
  final String agentId;
  final String taskId;
  final String channelId;
  final Map<String, dynamic> approvalData;
  final String status;
  final int createdAt;
  final int? expiresAt;
  final String? selectedActionId;
  final String? selectedActionLabel;

  const PeerHubPendingApproval({
    required this.approvalId,
    required this.peerId,
    required this.requestId,
    required this.agentId,
    required this.taskId,
    required this.channelId,
    this.approvalData = const {},
    this.status = 'pending',
    required this.createdAt,
    this.expiresAt,
    this.selectedActionId,
    this.selectedActionLabel,
  });

  bool get isPending => status == 'pending';

  Map<String, dynamic> toMap() => {
        'approval_id': approvalId,
        'peer_id': peerId,
        'request_id': requestId,
        'agent_id': agentId,
        'task_id': taskId,
        'channel_id': channelId,
        'approval_data_json': jsonEncode(approvalData),
        'status': status,
        'created_at': createdAt,
        'expires_at': expiresAt,
        'selected_action_id': selectedActionId,
        'selected_action_label': selectedActionLabel,
      };

  factory PeerHubPendingApproval.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> data = const {};
    final raw = map['approval_data_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }
    return PeerHubPendingApproval(
      approvalId: map['approval_id'] as String,
      peerId: map['peer_id'] as String,
      requestId: map['request_id'] as String,
      agentId: map['agent_id'] as String,
      taskId: map['task_id'] as String? ?? '',
      channelId: map['channel_id'] as String,
      approvalData: data,
      status: map['status'] as String? ?? 'pending',
      createdAt: map['created_at'] as int? ?? 0,
      expiresAt: map['expires_at'] as int?,
      selectedActionId: map['selected_action_id'] as String?,
      selectedActionLabel: map['selected_action_label'] as String?,
    );
  }
}

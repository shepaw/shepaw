import 'dart:convert';

import 'workflow_models.dart';

/// Persisted peer tool-call approval blocking a workflow step.
class WorkflowPendingApproval {
  final String id;
  final String workflowId;
  final String stepId;
  final String channelId;
  final String agentId;
  final String agentName;
  final String peerId;
  final String remoteAgentId;
  final String confirmationId;
  final String peerSessionId;
  final String? messageId;
  final Map<String, dynamic> approvalData;
  final String status;
  final int createdAt;
  final int? expiresAt;

  const WorkflowPendingApproval({
    required this.id,
    required this.workflowId,
    required this.stepId,
    required this.channelId,
    required this.agentId,
    required this.agentName,
    required this.peerId,
    required this.remoteAgentId,
    required this.confirmationId,
    required this.peerSessionId,
    this.messageId,
    required this.approvalData,
    this.status = 'pending',
    required this.createdAt,
    this.expiresAt,
  });

  bool get isPending => status == 'pending';

  PeerApprovalRisk get risk {
    final raw = approvalData['_approvalRisk'] as String?;
    return raw == 'low' ? PeerApprovalRisk.low : PeerApprovalRisk.high;
  }

  WorkflowPeerApprovalPending toUiPending() => WorkflowPeerApprovalPending(
        workflowId: workflowId,
        stepId: stepId,
        agentId: agentId,
        agentName: agentName,
        messageId: messageId,
        prompt: approvalData['prompt'] as String?,
        risk: risk,
        confirmationId: confirmationId,
        approvalData: approvalData,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'workflow_id': workflowId,
        'step_id': stepId,
        'channel_id': channelId,
        'agent_id': agentId,
        'agent_name': agentName,
        'peer_id': peerId,
        'remote_agent_id': remoteAgentId,
        'confirmation_id': confirmationId,
        'peer_session_id': peerSessionId,
        'message_id': messageId,
        'approval_data_json': jsonEncode(approvalData),
        'status': status,
        'created_at': createdAt,
        'expires_at': expiresAt,
      };

  factory WorkflowPendingApproval.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> data = const {};
    final raw = map['approval_data_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try {
        data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }
    return WorkflowPendingApproval(
      id: map['id'] as String,
      workflowId: map['workflow_id'] as String,
      stepId: map['step_id'] as String,
      channelId: map['channel_id'] as String,
      agentId: map['agent_id'] as String,
      agentName: map['agent_name'] as String? ?? '',
      peerId: map['peer_id'] as String,
      remoteAgentId: map['remote_agent_id'] as String,
      confirmationId: map['confirmation_id'] as String,
      peerSessionId: map['peer_session_id'] as String? ?? '',
      messageId: map['message_id'] as String?,
      approvalData: data,
      status: map['status'] as String? ?? 'pending',
      createdAt: map['created_at'] as int? ?? 0,
      expiresAt: map['expires_at'] as int?,
    );
  }
}

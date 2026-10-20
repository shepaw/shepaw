/// High-priority approval kinds surfaced by [PendingApprovalHub].
enum PendingApprovalKind {
  plan,
  action,
}

/// A cross-channel pending approval reminder (not the approval card itself).
class PendingApprovalItem {
  final String id;
  final String channelId;
  final String? messageId;
  final String agentId;
  final String agentName;
  final PendingApprovalKind kind;
  final int createdAt;

  const PendingApprovalItem({
    required this.id,
    required this.channelId,
    this.messageId,
    required this.agentId,
    required this.agentName,
    required this.kind,
    required this.createdAt,
  });

  PendingApprovalItem copyWith({
    String? channelId,
    String? messageId,
    String? agentName,
    int? createdAt,
  }) =>
      PendingApprovalItem(
        id: id,
        channelId: channelId ?? this.channelId,
        messageId: messageId ?? this.messageId,
        agentId: agentId,
        agentName: agentName ?? this.agentName,
        kind: kind,
        createdAt: createdAt ?? this.createdAt,
      );

  static String planId(String workflowId) => 'plan:$workflowId';

  static String actionId(String confirmationId) => 'action:$confirmationId';

  static String fallbackId({
    required PendingApprovalKind kind,
    required String channelId,
    String? messageId,
    String? agentId,
  }) {
    final prefix = kind == PendingApprovalKind.plan ? 'plan' : 'action';
    final tail = messageId ?? agentId ?? 'unknown';
    return '$prefix:$channelId:$tail';
  }

  /// Build from a group/DM interaction payload, or null if kind is out of M1.
  static PendingApprovalItem? fromInteraction({
    required String channelId,
    required String agentId,
    required String agentName,
    required String interactionType,
    required Map<String, dynamic> data,
    String? messageId,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (interactionType == 'plan_approval') {
      final workflowId = data['_workflowId'] as String?;
      return PendingApprovalItem(
        id: workflowId != null
            ? planId(workflowId)
            : fallbackId(
                kind: PendingApprovalKind.plan,
                channelId: channelId,
                messageId: messageId,
                agentId: agentId,
              ),
        channelId: channelId,
        messageId: messageId,
        agentId: agentId,
        agentName: agentName,
        kind: PendingApprovalKind.plan,
        createdAt: now,
      );
    }
    // 表单卡与审批卡同属「等用户点一下」的提醒，用同一套 id 前缀，
    // `resolveByConfirmationId(formId)` 提交后就能清掉。没有 form_id 的表单
    // 事后无从消解，宁可不提醒，免得横幅永远挂着。
    if (interactionType == 'form') {
      final formId = data['form_id'] as String?;
      if (formId == null || formId.isEmpty) return null;
      return PendingApprovalItem(
        id: actionId(formId),
        channelId: channelId,
        messageId: messageId,
        agentId: agentId,
        agentName: agentName,
        kind: PendingApprovalKind.action,
        createdAt: now,
      );
    }
    if (interactionType == 'action_confirmation') {
      final confirmationId = data['confirmation_id'] as String?;
      return PendingApprovalItem(
        id: confirmationId != null
            ? actionId(confirmationId)
            : fallbackId(
                kind: PendingApprovalKind.action,
                channelId: channelId,
                messageId: messageId,
                agentId: agentId,
              ),
        channelId: channelId,
        messageId: messageId,
        agentId: agentId,
        agentName: agentName,
        kind: PendingApprovalKind.action,
        createdAt: now,
      );
    }
    return null;
  }
}

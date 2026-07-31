import '../../models/message.dart';
import '../../models/workflow_models.dart';
import '../logger_service.dart';
import '../workflow/workflow_service.dart';
import 'pending_approval_item.dart';

/// Decides whether a [PendingApprovalItem] still needs reachability UI.
class PendingApprovalReconciler {
  PendingApprovalReconciler._();

  static const _tag = 'PendingApprovalReconciler';

  static bool isPlanMessageResolved(Message msg) {
    final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
    if (plan == null) return false;
    final responded =
        msg.metadata?['plan_approval_responded'] as Map<String, dynamic>?;
    return responded != null || plan['_approved'] != null;
  }

  static bool isActionMessageResolved(Message msg) {
    final ac = msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
    if (ac == null) return false;
    if (ac['selected_action_id'] != null) return true;
    final responded =
        msg.metadata?['action_confirmation_responded'] as Map<String, dynamic>?;
    return responded != null;
  }

  static bool? planApprovalDecision(Message msg) {
    if (!isPlanMessageResolved(msg)) return null;
    final responded =
        msg.metadata?['plan_approval_responded'] as Map<String, dynamic>?;
    if (responded != null) {
      return responded['approved'] as bool?;
    }
    final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
    return plan?['_approved'] as bool?;
  }

  static String? actionSelectedId(Message msg) {
    final ac = msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
    if (ac != null) {
      final selected = ac['selected_action_id'] as String?;
      if (selected != null && selected.isNotEmpty) return selected;
    }
    final responded =
        msg.metadata?['action_confirmation_responded'] as Map<String, dynamic>?;
    final fromResponded = responded?['action_id'] as String?;
    if (fromResponded != null && fromResponded.isNotEmpty) return fromResponded;
    return null;
  }

  /// First chat message that shows this hub item as already answered.
  static Message? findResolvedMessage(
    PendingApprovalItem item,
    Iterable<Message> messages,
  ) {
    if (item.messageId != null) {
      for (final msg in messages) {
        if (msg.id != item.messageId) continue;
        final resolved = switch (item.kind) {
          PendingApprovalKind.plan => isPlanMessageResolved(msg),
          PendingApprovalKind.action => isActionMessageResolved(msg),
        };
        if (resolved) return msg;
      }
    }

    final parsed = _parseHubId(item);
    for (final msg in messages) {
      switch (item.kind) {
        case PendingApprovalKind.plan:
          final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
          if (plan == null) continue;
          if (parsed.workflowId != null &&
              plan['_workflowId'] == parsed.workflowId &&
              isPlanMessageResolved(msg)) {
            return msg;
          }
        case PendingApprovalKind.action:
          final ac = msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
          if (ac == null) continue;
          if (parsed.confirmationId != null &&
              ac['confirmation_id'] == parsed.confirmationId &&
              isActionMessageResolved(msg)) {
            return msg;
          }
      }
    }
    return null;
  }

  static bool isResolvedInMessages(
    PendingApprovalItem item,
    Iterable<Message> messages,
  ) =>
      findResolvedMessage(item, messages) != null;

  /// Replay missing workflow DB updates when chat metadata already shows a decision.
  static Future<void> healStalePersistence({
    required PendingApprovalItem item,
    required Iterable<Message> messages,
    required WorkflowService workflowService,
  }) async {
    final resolvedMessage = findResolvedMessage(item, messages);
    if (resolvedMessage == null) return;

    try {
      switch (item.kind) {
        case PendingApprovalKind.plan:
          await _healPlan(item, resolvedMessage, workflowService);
        case PendingApprovalKind.action:
          await _healAction(item, resolvedMessage, workflowService);
      }
    } catch (e) {
      LoggerService().warning(
        'Failed to heal stale approval persistence for ${item.id}: $e',
        tag: _tag,
      );
    }
  }

  static Future<void> _healPlan(
    PendingApprovalItem item,
    Message resolvedMessage,
    WorkflowService workflowService,
  ) async {
    final workflowId = _parseHubId(item).workflowId;
    if (workflowId == null) return;

    final exec =
        await workflowService.getWorkflowExecutionWithSteps(workflowId);
    if (exec == null || exec.status != WorkflowStatus.pendingApproval) return;

    final approved = planApprovalDecision(resolvedMessage);
    if (approved == null) return;

    if (approved) {
      await workflowService.startWorkflow(workflowId);
    } else {
      await workflowService.cancelWorkflow(workflowId);
    }
    LoggerService().info(
      'Healed stale plan approval for $workflowId (approved=$approved)',
      tag: _tag,
    );
  }

  static Future<void> _healAction(
    PendingApprovalItem item,
    Message resolvedMessage,
    WorkflowService workflowService,
  ) async {
    final confirmationId = _parseHubId(item).confirmationId;
    if (confirmationId == null) return;

    final record =
        await workflowService.getPendingApprovalById(confirmationId);
    if (record == null || !record.isPending) return;

    await workflowService.markPendingApprovalSubmitted(
      confirmationId,
      selectedActionId: actionSelectedId(resolvedMessage),
    );
    LoggerService().info(
      'Healed stale action approval for $confirmationId',
      tag: _tag,
    );
  }

  /// Returns true when the banner / badge should still remind the user.
  static Future<bool> isStillPending({
    required PendingApprovalItem item,
    required Iterable<Message> messages,
    required WorkflowService workflowService,
  }) async {
    if (isResolvedInMessages(item, messages)) return false;

    switch (item.kind) {
      case PendingApprovalKind.plan:
        final workflowId = _parseHubId(item).workflowId;
        if (workflowId != null) {
          final exec =
              await workflowService.getWorkflowExecutionWithSteps(workflowId);
          if (exec != null && exec.status != WorkflowStatus.pendingApproval) {
            return false;
          }
        }
        return _hasUnansweredPlanMatch(item, messages);
      case PendingApprovalKind.action:
        final confirmationId = _parseHubId(item).confirmationId;
        if (confirmationId != null) {
          final record =
              await workflowService.getPendingApprovalById(confirmationId);
          if (record != null && !record.isPending) return false;
          if (record != null && record.isPending) return true;
        }
        return _hasUnansweredActionMatch(item, messages);
    }
  }

  static bool _hasUnansweredPlanMatch(
    PendingApprovalItem item,
    Iterable<Message> messages,
  ) {
    final parsed = _parseHubId(item);
    for (final msg in messages) {
      final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
      if (plan == null || isPlanMessageResolved(msg)) continue;
      if (item.messageId != null && msg.id == item.messageId) return true;
      if (parsed.workflowId != null &&
          plan['_workflowId'] == parsed.workflowId) {
        return true;
      }
    }
    return false;
  }

  static bool _hasUnansweredActionMatch(
    PendingApprovalItem item,
    Iterable<Message> messages,
  ) {
    final parsed = _parseHubId(item);
    for (final msg in messages) {
      final ac = msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
      if (ac == null || isActionMessageResolved(msg)) continue;
      if (item.messageId != null && msg.id == item.messageId) return true;
      if (parsed.confirmationId != null &&
          ac['confirmation_id'] == parsed.confirmationId) {
        return true;
      }
    }
    return false;
  }

  static _ParsedHubId _parseHubId(PendingApprovalItem item) {
    final prefix = item.kind == PendingApprovalKind.plan ? 'plan:' : 'action:';
    if (!item.id.startsWith(prefix)) {
      return const _ParsedHubId();
    }
    final rest = item.id.substring(prefix.length);
    if (!rest.contains(':')) {
      return item.kind == PendingApprovalKind.plan
          ? _ParsedHubId(workflowId: rest)
          : _ParsedHubId(confirmationId: rest);
    }
    return const _ParsedHubId();
  }
}

class _ParsedHubId {
  final String? workflowId;
  final String? confirmationId;

  const _ParsedHubId({this.workflowId, this.confirmationId});
}

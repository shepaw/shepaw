import 'dart:convert';

import '../../models/message.dart';
import '../../models/workflow_models.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../workflow/workflow_service.dart';
import 'pending_approval_item.dart';

/// Decides whether a [PendingApprovalItem] still needs reachability UI.
class PendingApprovalReconciler {
  PendingApprovalReconciler._();

  static const _tag = 'PendingApprovalReconciler';

  /// 「批准 → 补跑」只允许发生在刚创建不久的工作流上。
  ///
  /// 超过该窗口的已批准脏行几乎都来自跨设备审批（对端早已执行），
  /// 本地只补记终态，避免几周前的工作流在打开频道时被幽灵复活执行。
  static const replayWindow = Duration(hours: 24);

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

    if (approved &&
        DateTime.now().difference(exec.createdAt) <= replayWindow) {
      await workflowService.startWorkflow(workflowId);
    } else if (approved) {
      // 批准决定早已生效（多半已在其他设备执行过）：只补记终态，
      // 不通过 startWorkflow 复活执行。
      await workflowService.completeWorkflow(
        workflowId,
        summary: '审批决定此前已生效，启动对账时补记完成',
      );
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

  /// 全历史对账（启动 hydrate 用）：不受消息页窗口限制，直接按卡片 id
  /// 在消息表全文检索。
  ///
  /// 返回 true 表示确为待审、应保留提醒；false 表示可移除：
  /// - 找到已应答卡片 → 把决定回补进 workflow 表（见 [healStalePersistence]）；
  /// - 只有未应答卡片 → 真待审，保留；
  /// - 一张卡片都没有 → 孤儿行：重启后内存 Completer 已死，永远无人能答，
  ///   直接关闭（plan→取消；action→标记 submitted）。
  static Future<bool> reconcileWithDatabase({
    required PendingApprovalItem item,
    required WorkflowService workflowService,
    required LocalDatabaseService db,
  }) async {
    final parsed = _parseHubId(item);
    final hasStableId = switch (item.kind) {
      PendingApprovalKind.plan => parsed.workflowId != null,
      PendingApprovalKind.action => parsed.confirmationId != null,
    };
    // fallback id（plan:<channel>:<msg>）无法全文检索，交给窗口对账处理。
    if (!hasStableId) return true;

    final cards = await findApprovalCards(db: db, item: item);
    if (isResolvedInMessages(item, cards)) {
      await healStalePersistence(
        item: item,
        messages: cards,
        workflowService: workflowService,
      );
      return false;
    }
    if (cards.isNotEmpty) return true;

    await _closeOrphan(item, parsed, workflowService);
    return false;
  }

  /// 在 [db] 中查找 [item] 对应的全部持久化审批卡片（不限消息新旧）。
  static Future<List<Message>> findApprovalCards({
    required LocalDatabaseService db,
    required PendingApprovalItem item,
  }) async {
    final parsed = _parseHubId(item);
    final String? needle = switch (item.kind) {
      PendingApprovalKind.plan => parsed.workflowId != null
          ? '"_workflowId":"${parsed.workflowId}"'
          : null,
      PendingApprovalKind.action => parsed.confirmationId != null
          ? '"confirmation_id":"${parsed.confirmationId}"'
          : null,
    };
    if (needle == null) return const [];

    final rows = await db.getChannelMessagesByMetadataMatch(
      item.channelId,
      needle,
    );
    final cards = <Message>[];
    for (final row in rows) {
      final msg = _rowToMessage(row);
      if (msg != null && _isCardFor(item, msg, parsed)) cards.add(msg);
    }
    return cards;
  }

  /// 关闭一张卡片都不存在的孤儿审批行（重启后永远无人能答）。
  static Future<void> _closeOrphan(
    PendingApprovalItem item,
    _ParsedHubId parsed,
    WorkflowService workflowService,
  ) async {
    try {
      switch (item.kind) {
        case PendingApprovalKind.plan:
          final workflowId = parsed.workflowId!;
          final exec =
              await workflowService.getWorkflowExecutionWithSteps(workflowId);
          if (exec != null && exec.status == WorkflowStatus.pendingApproval) {
            await workflowService.cancelWorkflow(workflowId);
            LoggerService().info(
              'Closed orphaned plan approval $workflowId (no card found)',
              tag: _tag,
            );
          }
        case PendingApprovalKind.action:
          final confirmationId = parsed.confirmationId!;
          final record =
              await workflowService.getPendingApprovalById(confirmationId);
          if (record != null && record.isPending) {
            await workflowService.markPendingApprovalSubmitted(confirmationId);
            LoggerService().info(
              'Closed orphaned action approval $confirmationId '
              '(no card found)',
              tag: _tag,
            );
          }
      }
    } catch (e) {
      LoggerService().warning(
        'Failed to close orphaned approval ${item.id}: $e',
        tag: _tag,
      );
    }
  }

  /// LIKE 命中只保证子串存在，这里按解析后的 metadata 精确匹配卡片归属。
  static bool _isCardFor(
    PendingApprovalItem item,
    Message msg,
    _ParsedHubId parsed,
  ) {
    switch (item.kind) {
      case PendingApprovalKind.plan:
        final plan = msg.metadata?['plan_approval'] as Map<String, dynamic>?;
        return plan != null && plan['_workflowId'] == parsed.workflowId;
      case PendingApprovalKind.action:
        final ac =
            msg.metadata?['action_confirmation'] as Map<String, dynamic>?;
        return ac != null && ac['confirmation_id'] == parsed.confirmationId;
    }
  }

  static Message? _rowToMessage(Map<String, dynamic> row) {
    final id = row['id'] as String?;
    if (id == null) return null;
    Map<String, dynamic>? metadata;
    final raw = row['metadata'];
    if (raw is String && raw.isNotEmpty) {
      try {
        metadata = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {}
    }
    return Message(
      id: id,
      content: (row['content'] as String?) ?? '',
      timestampMs: DateTime.tryParse((row['created_at'] as String?) ?? '')
              ?.millisecondsSinceEpoch ??
          0,
      from: MessageFrom(
        id: (row['sender_id'] as String?) ?? '',
        type: (row['sender_type'] as String?) ?? 'agent',
        name: (row['sender_name'] as String?) ?? '',
      ),
      type: MessageType.text,
      metadata: metadata,
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

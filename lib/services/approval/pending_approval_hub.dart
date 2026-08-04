import 'dart:async';

import '../../models/workflow_models.dart';
import '../../models/workflow_pending_approval.dart';
import '../../models/message.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../workflow/workflow_service.dart';
import 'pending_approval_item.dart';
import 'pending_approval_reconciler.dart';

/// Global aggregator of high-priority pending approvals for reachability UI.
///
/// Approval cards still live in chat messages; this hub only tracks reminders
/// for list badges, in-app banner, and system notifications.
class PendingApprovalHub {
  PendingApprovalHub._();
  static final PendingApprovalHub instance = PendingApprovalHub._();

  static const _tag = 'PendingApprovalHub';

  final Map<String, PendingApprovalItem> _items = {};
  final Set<String> _dismissedIds = {};
  final _controller =
      StreamController<List<PendingApprovalItem>>.broadcast();

  bool _hydrated = false;

  List<PendingApprovalItem> get all {
    final list = _items.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Stream<List<PendingApprovalItem>> get stream async* {
    yield all;
    yield* _controller.stream;
  }

  List<PendingApprovalItem> itemsForChannel(String channelId) =>
      all.where((i) => i.channelId == channelId).toList();

  int countForChannel(String channelId) =>
      _items.values.where((i) => i.channelId == channelId).length;

  PendingApprovalItem? get latest => all.isEmpty ? null : all.first;

  void upsert(PendingApprovalItem item) {
    if (_dismissedIds.contains(item.id)) return;
    final existing = _items[item.id];
    if (existing != null) {
      final merged = existing.copyWith(
        messageId: item.messageId ?? existing.messageId,
        agentName:
            item.agentName.isNotEmpty ? item.agentName : existing.agentName,
      );
      // Skip no-op updates so reachability UI / notifications are not churned.
      if (merged.messageId == existing.messageId &&
          merged.agentName == existing.agentName &&
          merged.channelId == existing.channelId &&
          merged.agentId == existing.agentId &&
          merged.kind == existing.kind) {
        return;
      }
      _items[item.id] = merged;
    } else {
      _items[item.id] = item;
    }
    _emit();
  }

  /// Insert without emitting; used by [hydrate] to batch one stream event.
  void _upsertSilent(PendingApprovalItem item) {
    if (_dismissedIds.contains(item.id)) return;
    final existing = _items[item.id];
    if (existing != null) {
      _items[item.id] = existing.copyWith(
        messageId: item.messageId ?? existing.messageId,
        agentName:
            item.agentName.isNotEmpty ? item.agentName : existing.agentName,
      );
    } else {
      _items[item.id] = item;
    }
  }

  void resolve(String id) {
    _dismissedIds.remove(id);
    if (_items.remove(id) != null) {
      _emit();
    }
  }

  /// User dismissed the reachability banner; keep the in-chat approval card.
  void dismiss(String id) {
    _dismissedIds.add(id);
    if (_items.remove(id) != null) {
      _emit();
      LoggerService().info('Dismissed approval reminder $id', tag: _tag);
    }
  }

  void resolveByWorkflowId(String workflowId) => resolve(PendingApprovalItem.planId(workflowId));

  void resolveByConfirmationId(String confirmationId) =>
      resolve(PendingApprovalItem.actionId(confirmationId));

  void resolveChannel(String channelId) {
    final ids = _items.values
        .where((i) => i.channelId == channelId)
        .map((i) => i.id)
        .toList();
    if (ids.isEmpty) return;
    for (final id in ids) {
      _items.remove(id);
    }
    _emit();
  }

  /// Drop hub reminders that no longer match message / DB state.
  ///
  /// Called after [loadMessages] so a resolved in-chat card cannot keep
  /// reviving the global approval banner when the user leaves the channel.
  /// When chat metadata shows a decision but workflow tables are still pending,
  /// also replays the missing DB lifecycle update.
  Future<void> reconcileForChannel(
    String channelId,
    Iterable<Message> messages, {
    WorkflowService? workflowService,
  }) async {
    final channelItems =
        _items.values.where((i) => i.channelId == channelId).toList();
    if (channelItems.isEmpty) return;

    final wf = workflowService ?? WorkflowService.instance;
    var changed = false;
    for (final item in channelItems) {
      final stillPending = await PendingApprovalReconciler.isStillPending(
        item: item,
        messages: messages,
        workflowService: wf,
      );
      if (stillPending) continue;

      await PendingApprovalReconciler.healStalePersistence(
        item: item,
        messages: messages,
        workflowService: wf,
      );
      if (_items.remove(item.id) != null) {
        changed = true;
      }
    }
    if (changed) {
      _emit();
      LoggerService().info(
        'Reconciled stale approval reminder(s) for $channelId',
        tag: _tag,
      );
    }
  }

  /// Load durable pending approvals from DB (safe to call multiple times).
  ///
  /// Every restored row is reconciled against the FULL message history
  /// (no recency window): rows whose card was already answered replay their
  /// terminal state into the workflow tables, orphan rows with no card at
  /// all are closed, and only genuinely unanswered cards keep a reminder.
  Future<void> hydrate({
    WorkflowService? workflowService,
    LocalDatabaseService? db,
  }) async {
    if (_hydrated) return;
    _hydrated = true;
    final wf = workflowService ?? WorkflowService.instance;
    final database = db ?? LocalDatabaseService();
    try {
      final plans = await wf.getWorkflowsByStatus(WorkflowStatus.pendingApproval);
      for (final exec in plans) {
        _upsertSilent(
          PendingApprovalItem(
            id: PendingApprovalItem.planId(exec.id),
            channelId: exec.channelId,
            messageId: null,
            agentId: '',
            agentName: exec.title.isNotEmpty ? exec.title : 'Workflow',
            kind: PendingApprovalKind.plan,
            createdAt: exec.createdAt.millisecondsSinceEpoch,
          ),
        );
      }

      final actions = await wf.getAllPendingApprovals();
      for (final a in actions) {
        _upsertSilent(_fromWorkflowPending(a));
      }

      for (final item in _items.values.toList()) {
        try {
          final keep = await PendingApprovalReconciler.reconcileWithDatabase(
            item: item,
            workflowService: wf,
            db: database,
          );
          if (!keep) _items.remove(item.id);
        } catch (e) {
          LoggerService().warning(
            'Hydrate reconcile failed for ${item.id}: $e',
            tag: _tag,
          );
        }
      }
      _emit();

      LoggerService().info(
        'Hydrated ${_items.length} pending approval(s)',
        tag: _tag,
      );
    } catch (e) {
      LoggerService().warning('Hydrate failed: $e', tag: _tag);
      // Allow retry on next call.
      _hydrated = false;
    }
  }

  /// Test helper: clear in-memory state.
  void resetForTest() {
    _items.clear();
    _dismissedIds.clear();
    _hydrated = false;
    _emit();
  }

  void _emit() {
    if (!_controller.isClosed) {
      _controller.add(all);
    }
  }

  static PendingApprovalItem _fromWorkflowPending(WorkflowPendingApproval a) {
    return PendingApprovalItem(
      id: PendingApprovalItem.actionId(a.confirmationId),
      channelId: a.channelId,
      messageId: a.messageId,
      agentId: a.agentId,
      agentName: a.agentName.isNotEmpty ? a.agentName : a.agentId,
      kind: PendingApprovalKind.action,
      createdAt: a.createdAt,
    );
  }
}

import 'package:sqflite/sqflite.dart';
import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/planning_models.dart';
import '../../models/workflow_models.dart';
import '../../models/workflow_pending_approval.dart';
import '../approval/pending_approval_hub.dart';
import '../approval/pending_approval_item.dart';
import '../local_database_service.dart';
import '../logger_service.dart';

/// Service for managing workflow execution persistence and lifecycle.
///
/// Responsible for CRUD operations on workflow_executions and
/// workflow_step_executions tables, plus real-time notifications
/// for UI updates via streams.
class WorkflowService {
  /// Global singleton instance.
  static final WorkflowService instance = WorkflowService._(db: LocalDatabaseService());

  final LocalDatabaseService _db;
  final Uuid _uuid = const Uuid();

  /// Broadcast controller that fires whenever any workflow is updated.
  /// Listeners re-read from DB on notification.
  final StreamController<String> _updateController =
      StreamController<String>.broadcast();

  /// H4: Cache workflowId → channelId to avoid unnecessary cross-channel queries.
  final Map<String, String> _workflowChannelCache = {};

  WorkflowService._({required LocalDatabaseService db}) : _db = db;

  /// Constructor for dependency injection (delegates to singleton in practice).
  factory WorkflowService({required LocalDatabaseService db}) => instance;

  /// Dispose resources.
  void dispose() {
    _updateController.close();
  }

  // ===========================================================================
  // Create
  // ===========================================================================

  /// Create a new workflow execution from a FlowPlan.
  ///
  /// Inserts the workflow record and all step records (one per FlowStep across all stages).
  /// Returns the created [WorkflowExecution] with populated steps list.
  Future<WorkflowExecution> createWorkflowExecution({
    required String channelId,
    required String title,
    required FlowPlan flowPlan,
    String? triggerMessage,
  }) async {
    final now = DateTime.now();
    final workflowId = _uuid.v4();

    final execution = WorkflowExecution(
      id: workflowId,
      channelId: channelId,
      title: title.isNotEmpty ? title : (flowPlan.title.isNotEmpty ? flowPlan.title : '工作流'),
      flowPlanJson: _encodePlan(flowPlan),
      status: WorkflowStatus.pendingApproval,
      createdAt: now,
      triggerMessage: triggerMessage,
    );

    final db = await _db.database;

    // M6: Use transaction to ensure atomic creation of workflow + steps
    final steps = <WorkflowStepExecution>[];
    await db.transaction((txn) async {
      await txn.insert('workflow_executions', execution.toMap());

      // Insert step records
      for (int si = 0; si < flowPlan.stages.length; si++) {
        final stage = flowPlan.stages[si];
        for (int sti = 0; sti < stage.steps.length; sti++) {
          final step = stage.steps[sti];
          final stepExec = WorkflowStepExecution(
            id: _uuid.v4(),
            workflowExecutionId: workflowId,
            stageIndex: si,
            stepIndex: sti,
            stageName: stage.label,
            agentName: step.agent,
            instruction: step.instruction,
            status: step.status == TaskStatus.skipped
                ? StepExecutionStatus.skipped
                : StepExecutionStatus.pending,
          );
          await txn.insert('workflow_step_executions', stepExec.toMap());
          steps.add(stepExec);
        }
      }
    });

    execution.steps = steps;
    _workflowChannelCache[workflowId] = channelId;
    _notify(workflowId);
    LoggerService().info(
      'WorkflowService: created workflow $workflowId with ${steps.length} steps',
      tag: 'WorkflowService',
    );
    PendingApprovalHub.instance.upsert(
      PendingApprovalItem(
        id: PendingApprovalItem.planId(workflowId),
        channelId: channelId,
        agentId: '',
        agentName: execution.title.isNotEmpty ? execution.title : 'Workflow',
        kind: PendingApprovalKind.plan,
        createdAt: execution.createdAt.millisecondsSinceEpoch,
      ),
    );
    return execution;
  }

  // ===========================================================================
  // Read
  // ===========================================================================

  /// Get workflow executions for a channel, newest first.
  Future<List<WorkflowExecution>> getWorkflowExecutions(
    String channelId, {
    int limit = 50,
    int offset = 0,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_executions',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
    final executions = rows.map(WorkflowExecution.fromMap).toList();

    // Populate channel cache
    for (final exec in executions) {
      _workflowChannelCache[exec.id] = channelId;
    }

    // Load step counts for list display
    for (final exec in executions) {
      final stepRows = await db.query(
        'workflow_step_executions',
        where: 'workflow_execution_id = ?',
        whereArgs: [exec.id],
        orderBy: 'stage_index ASC, step_index ASC',
      );
      exec.steps = stepRows.map(WorkflowStepExecution.fromMap).toList();
    }
    return executions;
  }

  /// Get a single workflow execution with all step details.
  Future<WorkflowExecution?> getWorkflowExecutionWithSteps(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_executions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final execution = WorkflowExecution.fromMap(rows.first);
    final stepRows = await db.query(
      'workflow_step_executions',
      where: 'workflow_execution_id = ?',
      whereArgs: [id],
      orderBy: 'stage_index ASC, step_index ASC',
    );
    execution.steps = stepRows.map(WorkflowStepExecution.fromMap).toList();
    return execution;
  }

  /// Get the currently running workflow for a channel (at most one).
  Future<WorkflowExecution?> getActiveWorkflow(String channelId) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_executions',
      where: 'channel_id = ? AND status IN (?, ?)',
      whereArgs: [channelId, 'pending_approval', 'running'],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final execution = WorkflowExecution.fromMap(rows.first);
    final stepRows = await db.query(
      'workflow_step_executions',
      where: 'workflow_execution_id = ?',
      whereArgs: [execution.id],
      orderBy: 'stage_index ASC, step_index ASC',
    );
    execution.steps = stepRows.map(WorkflowStepExecution.fromMap).toList();
    return execution;
  }

  // ===========================================================================
  // Lifecycle Updates
  // ===========================================================================

  /// Mark workflow as running (user approved).
  /// Idempotent — only updates if current status is pendingApproval.
  Future<void> startWorkflow(String workflowId) async {
    final db = await _db.database;
    await db.update(
      'workflow_executions',
      {
        'status': WorkflowStatus.running.dbValue,
        'started_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ? AND status = ?',
      whereArgs: [workflowId, WorkflowStatus.pendingApproval.dbValue],
    );
    PendingApprovalHub.instance.resolveByWorkflowId(workflowId);
    _notify(workflowId);
  }

  /// Mark workflow as completed.
  ///
  /// Safety net: if any step ended in `failed`, the run is NOT a clean
  /// success — degrade to [failWorkflow] (with the failed members in
  /// [errorMessage]) so a partially-failed workflow is never surfaced as
  /// completed. Callers that want a degraded-complete outcome must resolve or
  /// retry the failed steps first.
  Future<void> completeWorkflow(String workflowId, {String? summary}) async {
    final db = await _db.database;

    // Never record a workflow with failed steps as completed.
    final failedRows = await db.query(
      'workflow_step_executions',
      columns: ['agent_name'],
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.failed.dbValue],
    );
    if (failedRows.isNotEmpty) {
      final failedNames = failedRows
          .map((r) => r['agent_name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
      final message = failedNames.isEmpty
          ? '存在失败步骤，工作流降级为失败'
          : '部分步骤失败：${failedNames.join('、')}';
      await failWorkflow(workflowId, message);
      return;
    }

    final updates = <String, dynamic>{
      'status': WorkflowStatus.completed.dbValue,
      'completed_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (summary != null) updates['summary'] = summary;
    await db.update(
      'workflow_executions',
      updates,
      where: 'id = ?',
      whereArgs: [workflowId],
    );
    // Mark any remaining pending steps as skipped
    await db.update(
      'workflow_step_executions',
      {'status': StepExecutionStatus.skipped.dbValue},
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.pending.dbValue],
    );
    _notify(workflowId);
  }

  /// Mark workflow as failed.
  Future<void> failWorkflow(String workflowId, String errorMessage) async {
    final db = await _db.database;
    await db.update(
      'workflow_executions',
      {
        'status': WorkflowStatus.failed.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [workflowId],
    );
    // H3: Cascade — mark running steps as failed, pending steps as skipped
    await db.update(
      'workflow_step_executions',
      {
        'status': StepExecutionStatus.failed.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'error_message': 'Workflow failed: $errorMessage',
      },
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.running.dbValue],
    );
    await db.update(
      'workflow_step_executions',
      {'status': StepExecutionStatus.skipped.dbValue},
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.pending.dbValue],
    );
    _notify(workflowId);
  }

  /// Mark workflow as cancelled (user rejected or aborted).
  Future<void> cancelWorkflow(String workflowId) async {
    final db = await _db.database;
    await db.update(
      'workflow_executions',
      {
        'status': WorkflowStatus.cancelled.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [workflowId],
    );
    // H3: Cascade — mark running steps as cancelled, pending steps as skipped
    await db.update(
      'workflow_step_executions',
      {
        'status': StepExecutionStatus.failed.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'error_message': 'Workflow cancelled',
      },
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.running.dbValue],
    );
    await db.update(
      'workflow_step_executions',
      {'status': StepExecutionStatus.skipped.dbValue},
      where: 'workflow_execution_id = ? AND status = ?',
      whereArgs: [workflowId, StepExecutionStatus.pending.dbValue],
    );
    PendingApprovalHub.instance.resolveByWorkflowId(workflowId);
    _notify(workflowId);
  }

  // ===========================================================================
  // Step Updates
  // ===========================================================================

  /// Mark a step as running.
  Future<void> startStep(String stepId) async {
    final db = await _db.database;
    await db.update(
      'workflow_step_executions',
      {
        'status': StepExecutionStatus.running.dbValue,
        'started_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [stepId],
    );
    final workflowId = await _getWorkflowIdForStep(stepId);
    if (workflowId != null) _notify(workflowId);
  }

  /// Mark a step as completed.
  Future<void> completeStep(String stepId, {String? outputSummary}) async {
    final db = await _db.database;
    final updates = <String, dynamic>{
      'status': StepExecutionStatus.completed.dbValue,
      'completed_at': DateTime.now().millisecondsSinceEpoch,
    };
    if (outputSummary != null) {
      // Truncate to max 500 chars
      updates['output_summary'] = outputSummary.length > 500
          ? '${outputSummary.substring(0, 497)}...'
          : outputSummary;
    }
    await db.update(
      'workflow_step_executions',
      updates,
      where: 'id = ?',
      whereArgs: [stepId],
    );
    final workflowId = await _getWorkflowIdForStep(stepId);
    if (workflowId != null) _notify(workflowId);
  }

  /// Mark a step as failed.
  Future<void> failStep(String stepId, String errorMessage) async {
    final db = await _db.database;
    await db.update(
      'workflow_step_executions',
      {
        'status': StepExecutionStatus.failed.dbValue,
        'completed_at': DateTime.now().millisecondsSinceEpoch,
        'error_message': errorMessage,
      },
      where: 'id = ?',
      whereArgs: [stepId],
    );
    final workflowId = await _getWorkflowIdForStep(stepId);
    if (workflowId != null) _notify(workflowId);
  }

  /// Mark a step as skipped.
  Future<void> skipStep(String stepId) async {
    final db = await _db.database;
    await db.update(
      'workflow_step_executions',
      {'status': StepExecutionStatus.skipped.dbValue},
      where: 'id = ?',
      whereArgs: [stepId],
    );
    final workflowId = await _getWorkflowIdForStep(stepId);
    if (workflowId != null) _notify(workflowId);
  }

  /// Rewrite the executing agent of a step — used by the stage gate's
  /// `reassign:名字` decision to hand subsequent pending steps to another
  /// member. Only meaningful for steps that have not started yet.
  Future<void> updateStepAgentName(String stepId, String agentName) async {
    final db = await _db.database;
    await db.update(
      'workflow_step_executions',
      {'agent_name': agentName},
      where: 'id = ?',
      whereArgs: [stepId],
    );
    final workflowId = await _getWorkflowIdForStep(stepId);
    if (workflowId != null) _notify(workflowId);
  }

  // ===========================================================================
  // Reactive Streams
  // ===========================================================================

  /// Stream that emits updated [WorkflowExecution] whenever the specified workflow changes.
  Stream<WorkflowExecution?> watchWorkflow(String workflowId) {
    return _updateController.stream
        .where((id) => id == workflowId)
        .asyncMap((_) => getWorkflowExecutionWithSteps(workflowId));
  }

  /// Stream that emits whenever any workflow for [channelId] changes.
  /// H4 fix: Only fires when the updated workflow belongs to this channel.
  Stream<List<WorkflowExecution>> watchChannelWorkflows(String channelId) {
    return _updateController.stream
        .where((workflowId) {
          // Check cache first; if not cached, allow through (will be filtered by query)
          final cached = _workflowChannelCache[workflowId];
          return cached == null || cached == channelId;
        })
        .asyncMap((_) => getWorkflowExecutions(channelId));
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  Future<String?> _getWorkflowIdForStep(String stepId) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_step_executions',
      columns: ['workflow_execution_id'],
      where: 'id = ?',
      whereArgs: [stepId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['workflow_execution_id'] as String?;
  }

  void _notify(String workflowId) {
    if (!_updateController.isClosed) {
      _updateController.add(workflowId);
    }
  }

  String _encodePlan(FlowPlan plan) {
    try {
      return jsonEncode(plan.toJson());
    } catch (_) {
      return '{}';
    }
  }

  // ===========================================================================
  // Pending peer tool approvals (v23)
  // ===========================================================================

  /// Insert or replace a pending peer approval blocking a workflow step.
  Future<void> savePendingApproval(WorkflowPendingApproval approval) async {
    final db = await _db.database;
    await db.insert(
      'workflow_pending_approvals',
      approval.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    PendingApprovalHub.instance.upsert(
      PendingApprovalItem(
        id: PendingApprovalItem.actionId(approval.confirmationId),
        channelId: approval.channelId,
        messageId: approval.messageId,
        agentId: approval.agentId,
        agentName:
            approval.agentName.isNotEmpty ? approval.agentName : approval.agentId,
        kind: PendingApprovalKind.action,
        createdAt: approval.createdAt,
      ),
    );
    _notify(approval.workflowId);
  }

  /// Attach the chat message that surfaced the approval card.
  Future<void> updatePendingApprovalMessageId(
    String approvalId,
    String messageId,
  ) async {
    final db = await _db.database;
    await db.update(
      'workflow_pending_approvals',
      {'message_id': messageId},
      where: 'id = ? OR confirmation_id = ?',
      whereArgs: [approvalId, approvalId],
    );
    final pending = await getPendingApprovalById(approvalId);
    if (pending != null) {
      PendingApprovalHub.instance.upsert(
        PendingApprovalItem(
          id: PendingApprovalItem.actionId(pending.confirmationId),
          channelId: pending.channelId,
          messageId: messageId,
          agentId: pending.agentId,
          agentName: pending.agentName.isNotEmpty
              ? pending.agentName
              : pending.agentId,
          kind: PendingApprovalKind.action,
          createdAt: pending.createdAt,
        ),
      );
      _notify(pending.workflowId);
    }
  }

  /// Mark a pending approval as submitted after the user taps Allow/Deny.
  Future<void> markPendingApprovalSubmitted(
    String approvalId, {
    String? selectedActionId,
  }) async {
    final db = await _db.database;
    final data = <String, dynamic>{'status': 'submitted'};
    if (selectedActionId != null) {
      final pending = await getPendingApprovalById(approvalId);
      if (pending != null) {
        final merged = Map<String, dynamic>.from(pending.approvalData);
        merged['selected_action_id'] = selectedActionId;
        data['approval_data_json'] = jsonEncode(merged);
      }
    }
    await db.update(
      'workflow_pending_approvals',
      data,
      where: 'id = ? OR confirmation_id = ?',
      whereArgs: [approvalId, approvalId],
    );
    final pending = await getPendingApprovalById(approvalId);
    if (pending != null) {
      PendingApprovalHub.instance
          .resolveByConfirmationId(pending.confirmationId);
      _notify(pending.workflowId);
    }
  }

  Future<WorkflowPendingApproval?> getPendingApprovalById(String id) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_pending_approvals',
      where: 'id = ? OR confirmation_id = ?',
      whereArgs: [id, id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WorkflowPendingApproval.fromMap(rows.first);
  }

  /// Latest pending approval for a workflow (at most one active).
  Future<WorkflowPendingApproval?> getPendingApprovalForWorkflow(
    String workflowId,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_pending_approvals',
      where: 'workflow_id = ? AND status = ?',
      whereArgs: [workflowId, 'pending'],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return WorkflowPendingApproval.fromMap(rows.first);
  }

  /// All pending approvals for a channel (newest first).
  Future<List<WorkflowPendingApproval>> getPendingApprovalsForChannel(
    String channelId,
  ) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_pending_approvals',
      where: 'channel_id = ? AND status = ?',
      whereArgs: [channelId, 'pending'],
      orderBy: 'created_at DESC',
    );
    return rows.map(WorkflowPendingApproval.fromMap).toList();
  }

  /// All pending peer tool approvals across channels (newest first).
  Future<List<WorkflowPendingApproval>> getAllPendingApprovals() async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_pending_approvals',
      where: 'status = ?',
      whereArgs: ['pending'],
      orderBy: 'created_at DESC',
    );
    return rows.map(WorkflowPendingApproval.fromMap).toList();
  }

  /// Workflows in a given status (newest first).
  Future<List<WorkflowExecution>> getWorkflowsByStatus(
    WorkflowStatus status, {
    int limit = 100,
  }) async {
    final db = await _db.database;
    final rows = await db.query(
      'workflow_executions',
      where: 'status = ?',
      whereArgs: [status.dbValue],
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map(WorkflowExecution.fromMap).toList();
  }
}

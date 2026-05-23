import 'dart:async';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/planning_models.dart';
import '../../models/workflow_models.dart';
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
    await db.insert('workflow_executions', execution.toMap());

    // Insert step records
    final steps = <WorkflowStepExecution>[];
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
        await db.insert('workflow_step_executions', stepExec.toMap());
        steps.add(stepExec);
      }
    }

    execution.steps = steps;
    _notify(workflowId);
    LoggerService().info(
      'WorkflowService: created workflow $workflowId with ${steps.length} steps',
      tag: 'WorkflowService',
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
  Future<void> startWorkflow(String workflowId) async {
    final db = await _db.database;
    await db.update(
      'workflow_executions',
      {
        'status': WorkflowStatus.running.dbValue,
        'started_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [workflowId],
    );
    _notify(workflowId);
  }

  /// Mark workflow as completed.
  Future<void> completeWorkflow(String workflowId, {String? summary}) async {
    final db = await _db.database;
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
  Stream<List<WorkflowExecution>> watchChannelWorkflows(String channelId) {
    return _updateController.stream.asyncMap((_) => getWorkflowExecutions(channelId));
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
}

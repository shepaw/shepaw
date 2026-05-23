import 'dart:convert';

// ---------------------------------------------------------------------------
// WorkflowStatus — lifecycle state of a workflow execution
// ---------------------------------------------------------------------------

enum WorkflowStatus {
  pendingApproval,
  running,
  completed,
  failed,
  cancelled;

  String get label {
    switch (this) {
      case WorkflowStatus.pendingApproval:
        return '待审批';
      case WorkflowStatus.running:
        return '运行中';
      case WorkflowStatus.completed:
        return '已完成';
      case WorkflowStatus.failed:
        return '失败';
      case WorkflowStatus.cancelled:
        return '已取消';
    }
  }

  String get dbValue {
    switch (this) {
      case WorkflowStatus.pendingApproval:
        return 'pending_approval';
      case WorkflowStatus.running:
        return 'running';
      case WorkflowStatus.completed:
        return 'completed';
      case WorkflowStatus.failed:
        return 'failed';
      case WorkflowStatus.cancelled:
        return 'cancelled';
    }
  }

  static WorkflowStatus fromDb(String? value) {
    switch (value) {
      case 'pending_approval':
        return WorkflowStatus.pendingApproval;
      case 'running':
        return WorkflowStatus.running;
      case 'completed':
        return WorkflowStatus.completed;
      case 'failed':
        return WorkflowStatus.failed;
      case 'cancelled':
        return WorkflowStatus.cancelled;
      default:
        return WorkflowStatus.pendingApproval;
    }
  }
}

// ---------------------------------------------------------------------------
// StepExecutionStatus — lifecycle state of a single step
// ---------------------------------------------------------------------------

enum StepExecutionStatus {
  pending,
  running,
  completed,
  failed,
  skipped;

  String get label {
    switch (this) {
      case StepExecutionStatus.pending:
        return '待执行';
      case StepExecutionStatus.running:
        return '执行中';
      case StepExecutionStatus.completed:
        return '已完成';
      case StepExecutionStatus.failed:
        return '失败';
      case StepExecutionStatus.skipped:
        return '已跳过';
    }
  }

  String get dbValue => name;

  static StepExecutionStatus fromDb(String? value) {
    switch (value) {
      case 'running':
        return StepExecutionStatus.running;
      case 'completed':
        return StepExecutionStatus.completed;
      case 'failed':
        return StepExecutionStatus.failed;
      case 'skipped':
        return StepExecutionStatus.skipped;
      default:
        return StepExecutionStatus.pending;
    }
  }
}

// ---------------------------------------------------------------------------
// WorkflowExecution — a single workflow run record
// ---------------------------------------------------------------------------

class WorkflowExecution {
  final String id;
  final String channelId;
  final String title;
  String? summary;
  final String flowPlanJson;
  WorkflowStatus status;
  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? completedAt;
  final String? triggerMessage;
  String? errorMessage;

  /// Loaded separately — list of step execution records.
  List<WorkflowStepExecution> steps;

  WorkflowExecution({
    required this.id,
    required this.channelId,
    required this.title,
    this.summary,
    required this.flowPlanJson,
    this.status = WorkflowStatus.pendingApproval,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.triggerMessage,
    this.errorMessage,
    this.steps = const [],
  });

  /// Duration from start to completion (or to now if still running).
  Duration? get duration {
    if (startedAt == null) return null;
    final end = completedAt ?? DateTime.now();
    return end.difference(startedAt!);
  }

  String get durationLabel {
    final d = duration;
    if (d == null) return '-';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    if (d.inMinutes < 60) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inHours}h ${d.inMinutes % 60}m';
  }

  int get totalStages {
    try {
      final plan = jsonDecode(flowPlanJson) as Map<String, dynamic>;
      return (plan['stages'] as List?)?.length ?? 0;
    } catch (_) {
      return 0;
    }
  }

  int get totalSteps => steps.length;

  int get completedSteps => steps
      .where((s) =>
          s.status == StepExecutionStatus.completed ||
          s.status == StepExecutionStatus.skipped)
      .length;

  int get runningSteps =>
      steps.where((s) => s.status == StepExecutionStatus.running).length;

  int get failedSteps =>
      steps.where((s) => s.status == StepExecutionStatus.failed).length;

  /// Current stage index (0-based) based on step progress.
  int get currentStageIndex {
    if (steps.isEmpty) return 0;
    for (final step in steps.reversed) {
      if (step.status == StepExecutionStatus.running ||
          step.status == StepExecutionStatus.completed) {
        return step.stageIndex;
      }
    }
    return 0;
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toMap() => {
        'id': id,
        'channel_id': channelId,
        'title': title,
        'summary': summary,
        'flow_plan_json': flowPlanJson,
        'status': status.dbValue,
        'created_at': createdAt.millisecondsSinceEpoch,
        'started_at': startedAt?.millisecondsSinceEpoch,
        'completed_at': completedAt?.millisecondsSinceEpoch,
        'trigger_message': triggerMessage,
        'error_message': errorMessage,
      };

  factory WorkflowExecution.fromMap(Map<String, dynamic> map) {
    return WorkflowExecution(
      id: map['id'] as String,
      channelId: map['channel_id'] as String,
      title: map['title'] as String? ?? '',
      summary: map['summary'] as String?,
      flowPlanJson: map['flow_plan_json'] as String? ?? '{}',
      status: WorkflowStatus.fromDb(map['status'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          map['created_at'] as int? ?? 0),
      startedAt: map['started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int)
          : null,
      completedAt: map['completed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['completed_at'] as int)
          : null,
      triggerMessage: map['trigger_message'] as String?,
      errorMessage: map['error_message'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// WorkflowStepExecution — execution record of a single step
// ---------------------------------------------------------------------------

class WorkflowStepExecution {
  final String id;
  final String workflowExecutionId;
  final int stageIndex;
  final int stepIndex;
  final String stageName;
  final String agentName;
  final String instruction;
  StepExecutionStatus status;
  DateTime? startedAt;
  DateTime? completedAt;
  String? outputSummary;
  String? errorMessage;

  WorkflowStepExecution({
    required this.id,
    required this.workflowExecutionId,
    required this.stageIndex,
    required this.stepIndex,
    this.stageName = '',
    required this.agentName,
    required this.instruction,
    this.status = StepExecutionStatus.pending,
    this.startedAt,
    this.completedAt,
    this.outputSummary,
    this.errorMessage,
  });

  /// Duration from start to completion (or to now if running).
  Duration? get duration {
    if (startedAt == null) return null;
    final end = completedAt ?? DateTime.now();
    return end.difference(startedAt!);
  }

  String get durationLabel {
    final d = duration;
    if (d == null) return '-';
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  // ---------------------------------------------------------------------------
  // Serialization
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toMap() => {
        'id': id,
        'workflow_execution_id': workflowExecutionId,
        'stage_index': stageIndex,
        'step_index': stepIndex,
        'stage_name': stageName,
        'agent_name': agentName,
        'instruction': instruction,
        'status': status.dbValue,
        'started_at': startedAt?.millisecondsSinceEpoch,
        'completed_at': completedAt?.millisecondsSinceEpoch,
        'output_summary': outputSummary,
        'error_message': errorMessage,
      };

  factory WorkflowStepExecution.fromMap(Map<String, dynamic> map) {
    return WorkflowStepExecution(
      id: map['id'] as String,
      workflowExecutionId: map['workflow_execution_id'] as String,
      stageIndex: map['stage_index'] as int? ?? 0,
      stepIndex: map['step_index'] as int? ?? 0,
      stageName: map['stage_name'] as String? ?? '',
      agentName: map['agent_name'] as String? ?? '',
      instruction: map['instruction'] as String? ?? '',
      status: StepExecutionStatus.fromDb(map['status'] as String?),
      startedAt: map['started_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['started_at'] as int)
          : null,
      completedAt: map['completed_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(map['completed_at'] as int)
          : null,
      outputSummary: map['output_summary'] as String?,
      errorMessage: map['error_message'] as String?,
    );
  }
}

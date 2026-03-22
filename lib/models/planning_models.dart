import 'dart:convert';

enum TaskStatus { pending, inProgress, done, failed, skipped }

class PlanTask {
  final String id;
  final String title;
  final String description;
  final String assignee;
  final List<String> dependencies;
  final String estimatedComplexity;
  TaskStatus status;

  PlanTask({
    required this.id,
    required this.title,
    required this.description,
    required this.assignee,
    required this.dependencies,
    required this.estimatedComplexity,
    this.status = TaskStatus.pending,
  });

  factory PlanTask.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String? ?? 'pending';
    final status = {
      'pending': TaskStatus.pending,
      'in_progress': TaskStatus.inProgress,
      'done': TaskStatus.done,
      'failed': TaskStatus.failed,
      'skipped': TaskStatus.skipped,
    }[statusStr] ?? TaskStatus.pending;

    return PlanTask(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      description: json['description'] as String? ?? '',
      assignee: json['assignee'] as String? ?? '',
      dependencies: (json['dependencies'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      estimatedComplexity:
          json['estimated_complexity'] as String? ?? 'medium',
      status: status,
    );
  }

  Map<String, dynamic> toJson() {
    final statusStr = {
      TaskStatus.pending: 'pending',
      TaskStatus.inProgress: 'in_progress',
      TaskStatus.done: 'done',
      TaskStatus.failed: 'failed',
      TaskStatus.skipped: 'skipped',
    }[status] ?? 'pending';

    return {
      'id': id,
      'title': title,
      'description': description,
      'assignee': assignee,
      'dependencies': dependencies,
      'estimated_complexity': estimatedComplexity,
      'status': statusStr,
    };
  }
}

class ExecutionPlan {
  final String title;
  final String summary;
  final List<PlanTask> tasks;

  ExecutionPlan({
    required this.title,
    required this.summary,
    required this.tasks,
  });

  factory ExecutionPlan.fromJson(Map<String, dynamic> json) {
    return ExecutionPlan(
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      tasks: (json['tasks'] as List?)
              ?.map((t) => PlanTask.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'summary': summary,
      'tasks': tasks.map((t) => t.toJson()).toList(),
    };
  }

  /// Parse [PLAN]...[/PLAN] block from Admin response text. Returns null on failure.
  static ExecutionPlan? tryParse(String text) {
    final match = RegExp(r'\[PLAN\]([\s\S]*?)\[/PLAN\]', caseSensitive: false)
        .firstMatch(text);
    if (match == null) return null;
    try {
      return ExecutionPlan.fromJson(
          jsonDecode(match.group(1)!.trim()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Remove [PLAN]...[/PLAN] block from text.
  static String stripPlanBlock(String text) =>
      text
          .replaceAll(
              RegExp(r'\[PLAN\][\s\S]*?\[/PLAN\]', caseSensitive: false), '')
          .trim();
}

// ---------------------------------------------------------------------------
// FlowPlan data model (stage + step structured execution plan)
// ---------------------------------------------------------------------------

enum FlowStageStatus { pending, running, done, failed }

class FlowStep {
  final String stepId;
  final String taskId;
  final String agent;
  final String instruction;
  final List<String> dependsOn;
  final String estimatedComplexity;
  TaskStatus status;

  FlowStep({
    required this.stepId,
    required this.taskId,
    required this.agent,
    required this.instruction,
    this.dependsOn = const [],
    this.estimatedComplexity = 'medium',
    this.status = TaskStatus.pending,
  });

  factory FlowStep.fromJson(Map<String, dynamic> json) {
    final statusStr = json['status'] as String? ?? 'pending';
    final status = {
      'pending': TaskStatus.pending,
      'in_progress': TaskStatus.inProgress,
      'done': TaskStatus.done,
      'failed': TaskStatus.failed,
      'skipped': TaskStatus.skipped,
    }[statusStr] ?? TaskStatus.pending;

    return FlowStep(
      stepId: json['step_id'] as String? ?? '',
      taskId: json['task_id'] as String? ?? '',
      agent: json['agent'] as String? ?? '',
      instruction: json['instruction'] as String? ?? '',
      dependsOn: (json['depends_on'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      estimatedComplexity: json['estimated_complexity'] as String? ?? 'medium',
      status: status,
    );
  }

  Map<String, dynamic> toJson() {
    final statusStr = {
      TaskStatus.pending: 'pending',
      TaskStatus.inProgress: 'in_progress',
      TaskStatus.done: 'done',
      TaskStatus.failed: 'failed',
      TaskStatus.skipped: 'skipped',
    }[status] ?? 'pending';

    return {
      'step_id': stepId,
      'task_id': taskId,
      'agent': agent,
      'instruction': instruction,
      'depends_on': dependsOn,
      'estimated_complexity': estimatedComplexity,
      'status': statusStr,
    };
  }

  /// Convert to PlanTask for use with existing UI components (TaskBoardWidget / PlanApprovalCard).
  PlanTask toPlanTask() => PlanTask(
        id: stepId,
        title: taskId,
        description: instruction,
        assignee: agent,
        dependencies: dependsOn,
        estimatedComplexity: estimatedComplexity,
        status: status,
      );
}

class FlowStage {
  final String stageId;
  final String label;
  final List<FlowStep> steps;
  FlowStageStatus status;

  FlowStage({
    required this.stageId,
    required this.label,
    required this.steps,
    this.status = FlowStageStatus.pending,
  });

  factory FlowStage.fromJson(Map<String, dynamic> json) {
    return FlowStage(
      stageId: json['stage_id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      steps: (json['steps'] as List?)
              ?.map((s) => FlowStep.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'stage_id': stageId,
      'label': label,
      'steps': steps.map((s) => s.toJson()).toList(),
    };
  }

  bool get isDone => steps.every(
      (s) => s.status == TaskStatus.done || s.status == TaskStatus.skipped);
  bool get hasFailed => steps.any((s) => s.status == TaskStatus.failed);
}

class FlowPlan {
  final String title;
  final String summary;
  final List<FlowStage> stages;

  FlowPlan({
    required this.title,
    required this.summary,
    required this.stages,
  });

  factory FlowPlan.fromJson(Map<String, dynamic> json) {
    return FlowPlan(
      title: json['title'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      stages: (json['stages'] as List?)
              ?.map((s) => FlowStage.fromJson(s as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'summary': summary,
      'stages': stages.map((s) => s.toJson()).toList(),
    };
  }

  /// Parse [FLOW_PLAN]...[/FLOW_PLAN] block from Admin response text. Returns null on failure.
  static FlowPlan? tryParse(String text) {
    final match =
        RegExp(r'\[FLOW_PLAN\]([\s\S]*?)\[/FLOW_PLAN\]', caseSensitive: false)
            .firstMatch(text);
    if (match == null) return null;
    try {
      return FlowPlan.fromJson(
          jsonDecode(match.group(1)!.trim()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Remove [FLOW_PLAN]...[/FLOW_PLAN] block from text.
  static String stripFlowPlanBlock(String text) =>
      text
          .replaceAll(
              RegExp(r'\[FLOW_PLAN\][\s\S]*?\[/FLOW_PLAN\]',
                  caseSensitive: false),
              '')
          .trim();

  /// Flatten all stages/steps into an ExecutionPlan for use with existing UI components.
  ExecutionPlan toExecutionPlan() {
    final tasks = stages
        .expand((stage) => stage.steps.map((step) => step.toPlanTask()))
        .toList();
    return ExecutionPlan(title: title, summary: summary, tasks: tasks);
  }

  /// Apply a set of skipped step_ids (matches stepId fields).
  void applySkippedStepIds(Set<String> skippedStepIds) {
    for (final stage in stages) {
      for (final step in stage.steps) {
        if (skippedStepIds.contains(step.stepId)) {
          step.status = TaskStatus.skipped;
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// FlowCtrlCommand — Admin inter-stage control directives
// ---------------------------------------------------------------------------

enum FlowCtrlAction { pause, resume, skipStep, retryTask, injectMessage, abort }

class FlowCtrlCommand {
  final FlowCtrlAction action;
  final String? targetStepId;
  final String? message;

  FlowCtrlCommand({
    required this.action,
    this.targetStepId,
    this.message,
  });

  /// Parse [FLOW_CTRL]...[/FLOW_CTRL] block from Admin response text. Returns null on failure.
  static FlowCtrlCommand? tryParse(String text) {
    final match =
        RegExp(r'\[FLOW_CTRL\]([\s\S]*?)\[/FLOW_CTRL\]', caseSensitive: false)
            .firstMatch(text);
    if (match == null) return null;
    try {
      final json =
          jsonDecode(match.group(1)!.trim()) as Map<String, dynamic>;
      final actionStr = (json['action'] as String? ?? '').toLowerCase();
      final action = const {
        'pause': FlowCtrlAction.pause,
        'resume': FlowCtrlAction.resume,
        'skip_step': FlowCtrlAction.skipStep,
        'retry_task': FlowCtrlAction.retryTask,
        'inject_message': FlowCtrlAction.injectMessage,
        'abort': FlowCtrlAction.abort,
      }[actionStr];
      if (action == null) return null;
      return FlowCtrlCommand(
        action: action,
        targetStepId: json['step_id'] as String?,
        message: json['message'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  /// Remove [FLOW_CTRL]...[/FLOW_CTRL] block from text.
  static String stripFlowCtrlBlock(String text) =>
      text
          .replaceAll(
              RegExp(r'\[FLOW_CTRL\][\s\S]*?\[/FLOW_CTRL\]',
                  caseSensitive: false),
              '')
          .trim();
}

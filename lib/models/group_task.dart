/// 群聊编排任务（一条用户消息 = 一个 Task，主键为 [orchestrationId]）。
///
/// 物理布局见 [GroupWorkspaceService.taskDir]：
/// `shared/tasks/<orchestrationId>/{task.json, requirement.md, plan.*, …}`。
class GroupTask {
  GroupTask({
    required this.orchestrationId,
    required this.sessionId,
    required this.status,
    required this.userGoal,
    this.requirementUri,
    this.planUri,
    this.planJsonUri,
    this.resultsUri,
    this.archiveUri,
    this.finalSummaryUri,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.finishedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  static const schemaVersion = 1;

  static const statusClarifying = 'clarifying';
  static const statusPlanned = 'planned';
  static const statusExecuting = 'executing';
  static const statusSummarizing = 'summarizing';
  static const statusDone = 'done';
  static const statusPaused = 'paused';
  static const statusFailed = 'failed';

  static const validStatuses = {
    statusClarifying,
    statusPlanned,
    statusExecuting,
    statusSummarizing,
    statusDone,
    statusPaused,
    statusFailed,
  };

  final String orchestrationId;
  final String sessionId;
  final String status;
  final String userGoal;
  final String? requirementUri;
  final String? planUri;
  final String? planJsonUri;
  final String? resultsUri;
  final String? archiveUri;
  final String? finalSummaryUri;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? finishedAt;

  bool get hasPublishedPlan =>
      planJsonUri != null &&
      planJsonUri!.trim().isNotEmpty &&
      (status == statusPlanned ||
          status == statusExecuting ||
          status == statusSummarizing ||
          status == statusDone);

  bool get isTerminal => isTerminalStatus(status);

  /// 单一事实：终态集合（done/failed/paused）。供索引条目、存储写回等无
  /// [GroupTask] 实例的上下文复用，避免多处内联漂移。
  static bool isTerminalStatus(String status) =>
      status == statusDone || status == statusFailed || status == statusPaused;

  GroupTask copyWith({
    String? sessionId,
    String? status,
    String? userGoal,
    String? requirementUri,
    String? planUri,
    String? planJsonUri,
    String? resultsUri,
    String? archiveUri,
    String? finalSummaryUri,
    DateTime? updatedAt,
    DateTime? finishedAt,
    bool clearFinishedAt = false,
  }) {
    return GroupTask(
      orchestrationId: orchestrationId,
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      userGoal: userGoal ?? this.userGoal,
      requirementUri: requirementUri ?? this.requirementUri,
      planUri: planUri ?? this.planUri,
      planJsonUri: planJsonUri ?? this.planJsonUri,
      resultsUri: resultsUri ?? this.resultsUri,
      archiveUri: archiveUri ?? this.archiveUri,
      finalSummaryUri: finalSummaryUri ?? this.finalSummaryUri,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      finishedAt: clearFinishedAt ? null : (finishedAt ?? this.finishedAt),
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'orchestration_id': orchestrationId,
        'session_id': sessionId,
        'status': status,
        'user_goal': userGoal,
        if (requirementUri != null) 'requirement_uri': requirementUri,
        if (planUri != null) 'plan_uri': planUri,
        if (planJsonUri != null) 'plan_json_uri': planJsonUri,
        if (resultsUri != null) 'results_uri': resultsUri,
        if (archiveUri != null) 'archive_uri': archiveUri,
        if (finalSummaryUri != null) 'final_summary_uri': finalSummaryUri,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
      };

  static GroupTask? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    final sessionId = json['session_id'] as String?;
    final status = json['status'] as String?;
    final userGoal = json['user_goal'] as String?;
    if (orchestrationId == null ||
        orchestrationId.isEmpty ||
        sessionId == null ||
        sessionId.isEmpty ||
        status == null ||
        status.isEmpty ||
        userGoal == null) {
      return null;
    }
    if (!validStatuses.contains(status)) return null;

    DateTime? parseTime(String? raw) {
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    }

    final createdAt = parseTime(json['created_at'] as String?) ?? DateTime.now();
    final updatedAt = parseTime(json['updated_at'] as String?) ?? createdAt;

    return GroupTask(
      orchestrationId: orchestrationId,
      sessionId: sessionId,
      status: status,
      userGoal: userGoal,
      requirementUri: json['requirement_uri'] as String?,
      planUri: json['plan_uri'] as String?,
      planJsonUri: json['plan_json_uri'] as String?,
      resultsUri: json['results_uri'] as String?,
      archiveUri: json['archive_uri'] as String?,
      finalSummaryUri: json['final_summary_uri'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      finishedAt: parseTime(json['finished_at'] as String?),
    );
  }
}

/// 结构化任务计划（与 `group_dispatch` steps 对齐，含任务级元数据）。
class GroupTaskPlan {
  GroupTaskPlan({
    required this.orchestrationId,
    required this.goal,
    required this.steps,
    this.acceptanceCriteria = const [],
    this.constraints = const [],
    this.issuedBy,
    DateTime? issuedAt,
  }) : issuedAt = issuedAt ?? DateTime.now();

  static const schemaVersion = 1;

  final String orchestrationId;
  final String goal;
  final List<String> acceptanceCriteria;
  final List<String> constraints;
  final List<GroupTaskPlanStep> steps;
  final String? issuedBy;
  final DateTime issuedAt;

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'orchestration_id': orchestrationId,
        'goal': goal,
        'acceptance_criteria': acceptanceCriteria,
        'constraints': constraints,
        'steps': [for (final s in steps) s.toJson()],
        if (issuedBy != null) 'issued_by': issuedBy,
        'issued_at': issuedAt.toIso8601String(),
      };

  static GroupTaskPlan? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    final goal = json['goal'] as String?;
    if (orchestrationId == null ||
        orchestrationId.isEmpty ||
        goal == null ||
        goal.trim().isEmpty) {
      return null;
    }
    final rawSteps = json['steps'];
    final steps = <GroupTaskPlanStep>[];
    if (rawSteps is List) {
      for (final raw in rawSteps) {
        if (raw is Map) {
          final step = GroupTaskPlanStep.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (step != null) steps.add(step);
        }
      }
    }
    if (steps.isEmpty) return null;

    final criteria = <String>[];
    final rawCriteria = json['acceptance_criteria'];
    if (rawCriteria is List) {
      for (final c in rawCriteria) {
        if (c is String && c.trim().isNotEmpty) criteria.add(c.trim());
      }
    }

    final constraints = <String>[];
    final rawConstraints = json['constraints'];
    if (rawConstraints is List) {
      for (final c in rawConstraints) {
        if (c is String && c.trim().isNotEmpty) constraints.add(c.trim());
      }
    }

    return GroupTaskPlan(
      orchestrationId: orchestrationId,
      goal: goal.trim(),
      acceptanceCriteria: criteria,
      constraints: constraints,
      steps: steps,
      issuedBy: json['issued_by'] as String?,
      issuedAt: DateTime.tryParse(json['issued_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// 人类可读的 plan.md 正文。
  String toMarkdown({String requirementNotes = ''}) {
    final buffer = StringBuffer()
      ..writeln('# 任务计划')
      ..writeln()
      ..writeln('## 目标')
      ..writeln(goal.trim())
      ..writeln();
    if (acceptanceCriteria.isNotEmpty) {
      buffer.writeln('## 验收标准');
      for (final c in acceptanceCriteria) {
        buffer.writeln('- $c');
      }
      buffer.writeln();
    }
    if (constraints.isNotEmpty) {
      buffer.writeln('## 约束');
      for (final c in constraints) {
        buffer.writeln('- $c');
      }
      buffer.writeln();
    }
    if (requirementNotes.trim().isNotEmpty) {
      buffer
        ..writeln('## 需求澄清摘要')
        ..writeln(requirementNotes.trim())
        ..writeln();
    }
    buffer.writeln('## 分工');
    for (final step in steps) {
      final agents = step.agents.join('、');
      buffer.writeln('- **步骤 ${step.step}**（${step.mode}）：$agents');
      buffer.writeln('  ${step.task.trim()}');
    }
    return buffer.toString().trim();
  }
}

class GroupTaskPlanStep {
  GroupTaskPlanStep({
    required this.step,
    required this.agents,
    required this.task,
    this.agentIds = const [],
    this.mode = 'concurrent',
  });

  final int step;
  final List<String> agents;
  final List<String> agentIds;
  final String task;
  final String mode;

  Map<String, dynamic> toJson() => {
        'step': step,
        'agents': agents,
        if (agentIds.isNotEmpty) 'agent_ids': agentIds,
        'task': task,
        'mode': mode,
      };

  static GroupTaskPlanStep? fromJson(Map<String, dynamic> json) {
    final stepNum = (json['step'] as num?)?.toInt();
    final task = json['task'] as String?;
    if (stepNum == null || task == null || task.trim().isEmpty) return null;

    final agents = <String>[];
    final rawAgents = json['agents'];
    if (rawAgents is List) {
      for (final a in rawAgents) {
        if (a is String && a.trim().isNotEmpty) agents.add(a.trim());
      }
    }
    if (agents.isEmpty) return null;

    final agentIds = <String>[];
    final rawIds = json['agent_ids'];
    if (rawIds is List) {
      for (final id in rawIds) {
        if (id is String && id.trim().isNotEmpty) agentIds.add(id.trim());
      }
    }

    final mode = (json['mode'] as String?)?.trim();
    return GroupTaskPlanStep(
      step: stepNum,
      agents: agents,
      agentIds: agentIds,
      task: task.trim(),
      mode: mode == 'sequential' ? 'sequential' : 'concurrent',
    );
  }
}

/// 单成员执行结果（[GroupTaskResults.members] 元素）。
class GroupTaskMemberResult {
  GroupTaskMemberResult({
    required this.agentId,
    required this.agentName,
    required this.taskStatus,
    this.round,
    this.summary = '',
    this.artifactUris = const [],
    this.messageId,
    DateTime? completedAt,
  }) : completedAt = completedAt ?? DateTime.now();

  static const statusDone = 'done';
  static const statusPending = 'pending';
  static const statusFailed = 'failed';
  static const statusStalled = 'stalled';

  static const validStatuses = {
    statusDone,
    statusPending,
    statusFailed,
    statusStalled,
  };

  final String agentId;
  final String agentName;
  final int? round;
  final String taskStatus;
  final String summary;
  final List<String> artifactUris;
  final String? messageId;
  final DateTime completedAt;

  Map<String, dynamic> toJson() => {
        'agent_id': agentId,
        'agent_name': agentName,
        if (round != null) 'round': round,
        'task_status': taskStatus,
        if (summary.isNotEmpty) 'summary': summary,
        if (artifactUris.isNotEmpty) 'artifact_uris': artifactUris,
        if (messageId != null) 'message_id': messageId,
        'completed_at': completedAt.toIso8601String(),
      };

  static GroupTaskMemberResult? fromJson(Map<String, dynamic> json) {
    final agentId = json['agent_id'] as String?;
    final agentName = json['agent_name'] as String?;
    final taskStatus = json['task_status'] as String?;
    if (agentId == null ||
        agentId.isEmpty ||
        agentName == null ||
        agentName.isEmpty ||
        taskStatus == null ||
        !validStatuses.contains(taskStatus)) {
      return null;
    }
    final uris = <String>[];
    final rawUris = json['artifact_uris'];
    if (rawUris is List) {
      for (final u in rawUris) {
        if (u is String && u.trim().isNotEmpty) uris.add(u.trim());
      }
    }
    return GroupTaskMemberResult(
      agentId: agentId,
      agentName: agentName,
      round: (json['round'] as num?)?.toInt(),
      taskStatus: taskStatus,
      summary: (json['summary'] as String?)?.trim() ?? '',
      artifactUris: uris,
      messageId: json['message_id'] as String?,
      completedAt:
          DateTime.tryParse(json['completed_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

/// 任务级成员结果汇总（`results.json`）。
class GroupTaskResults {
  GroupTaskResults({
    required this.orchestrationId,
    this.members = const [],
  });

  static const schemaVersion = 1;

  final String orchestrationId;
  final List<GroupTaskMemberResult> members;

  GroupTaskResults upsertMember(GroupTaskMemberResult entry) {
    // 去重键为 (agentId, round)：同一成员在后续轮被重新委派时应保留每一轮
    // 的交付记录，而不是被最近一轮覆盖（round 维度此前被压扁丢失）。
    final merged = [
      for (final m in members)
        if (m.agentId != entry.agentId || m.round != entry.round) m,
      entry,
    ];
    return GroupTaskResults(
      orchestrationId: orchestrationId,
      members: merged,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'orchestration_id': orchestrationId,
        'members': [for (final m in members) m.toJson()],
      };

  static GroupTaskResults? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    if (orchestrationId == null || orchestrationId.isEmpty) return null;
    final members = <GroupTaskMemberResult>[];
    final rawMembers = json['members'];
    if (rawMembers is List) {
      for (final raw in rawMembers) {
        if (raw is Map) {
          final m = GroupTaskMemberResult.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (m != null) members.add(m);
        }
      }
    }
    return GroupTaskResults(
      orchestrationId: orchestrationId,
      members: members,
    );
  }
}

/// 任务索引条目（[GroupTaskIndex.recent] 元素）。
class GroupTaskIndexEntry {
  GroupTaskIndexEntry({
    required this.orchestrationId,
    required this.status,
    required this.title,
    this.finishedAt,
  });

  final String orchestrationId;
  final String status;
  final String title;
  final DateTime? finishedAt;

  Map<String, dynamic> toJson() => {
        'orchestration_id': orchestrationId,
        'status': status,
        if (title.isNotEmpty) 'title': title,
        if (finishedAt != null) 'finished_at': finishedAt!.toIso8601String(),
      };

  static GroupTaskIndexEntry? fromJson(Map<String, dynamic> json) {
    final orchestrationId = json['orchestration_id'] as String?;
    final status = json['status'] as String?;
    if (orchestrationId == null ||
        orchestrationId.isEmpty ||
        status == null ||
        status.isEmpty) {
      return null;
    }
    final finishedRaw = json['finished_at'] as String?;
    return GroupTaskIndexEntry(
      orchestrationId: orchestrationId,
      status: status,
      title: (json['title'] as String?)?.trim() ?? '',
      finishedAt:
          finishedRaw == null ? null : DateTime.tryParse(finishedRaw),
    );
  }
}

/// 群任务轻量索引（`shared/tasks/index.json`）。
class GroupTaskIndex {
  GroupTaskIndex({
    this.activeOrchestrationId,
    this.recent = const [],
  });

  static const schemaVersion = 1;
  static const maxRecentEntries = 32;

  final String? activeOrchestrationId;
  final List<GroupTaskIndexEntry> recent;

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        if (activeOrchestrationId != null)
          'active_orchestration_id': activeOrchestrationId,
        'recent': [for (final e in recent) e.toJson()],
      };

  static GroupTaskIndex fromJson(Map<String, dynamic> json) {
    final recent = <GroupTaskIndexEntry>[];
    final rawRecent = json['recent'];
    if (rawRecent is List) {
      for (final raw in rawRecent) {
        if (raw is Map) {
          final e = GroupTaskIndexEntry.fromJson(
            Map<String, dynamic>.from(raw),
          );
          if (e != null) recent.add(e);
        }
      }
    }
    return GroupTaskIndex(
      activeOrchestrationId: json['active_orchestration_id'] as String?,
      recent: recent,
    );
  }

  GroupTaskIndex withActiveTask(GroupTask task) {
    final title = _titleFromGoal(task.userGoal);
    final without = recent
        .where((e) => e.orchestrationId != task.orchestrationId)
        .toList();
    final entry = GroupTaskIndexEntry(
      orchestrationId: task.orchestrationId,
      status: task.status,
      title: title,
      finishedAt: task.finishedAt,
    );
    return GroupTaskIndex(
      activeOrchestrationId: task.isTerminal ? null : task.orchestrationId,
      recent: [entry, ...without].take(maxRecentEntries).toList(),
    );
  }

  static String _titleFromGoal(String userGoal) {
    final trimmed = userGoal.trim();
    if (trimmed.length <= 80) return trimmed;
    return '${trimmed.substring(0, 80)}…';
  }
}

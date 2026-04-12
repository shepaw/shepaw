import 'dart:convert';

/// Represents a scheduled task in the system.
///
/// Supports three scheduling types (taskType):
/// - `cron`: Cron expression (e.g., "0 9 * * *" for 9am daily)
/// - `interval`: ISO 8601 duration (e.g., "PT5M" for every 5 minutes)
/// - `once`: One-time execution at nextRunAt timestamp
///
/// Supports two execution targets (executionTarget):
/// - `agent`: Send the instruction to a single agent (requires agentId)
/// - `group`: Broadcast the instruction to a group channel (requires channelId + agentIds)
class ScheduledTask {
  final String id;                        // UUID v4
  final String? agentId;                  // Agent task: required; Group task: null
  final String? channelId;               // Agent task: optional DM override; Group task: required
  final String taskType;                  // 'interval', 'cron', 'once'
  final String description;              // Human-readable task description
  final String status;                   // 'pending', 'active', 'paused', 'completed', 'failed'

  final String instruction;              // Task/prompt to execute
  final Map<String, dynamic>? parameters; // Task-specific configuration

  final String schedulePattern;          // Cron pattern or ISO 8601 duration
  final int? lastRunAt;                  // Last execution timestamp (ms)
  final int nextRunAt;                   // Next execution timestamp (ms)

  final int executionCount;              // Total successful executions
  final int failureCount;                // Total failed executions
  final String? lastError;              // Error message from last failed run

  final int createdAt;                   // Creation timestamp (ms)
  final int updatedAt;                   // Last update timestamp (ms)
  final String createdBy;               // User ID who created the task

  // -- Group task fields --
  final String executionTarget;          // 'agent' | 'group'
  final List<String> agentIds;           // Group task: all participating agents
  final List<String> mentionedAgentIds; // Group task: subset to @-mention

  // Status constants
  static const String statusPending = 'pending';
  static const String statusActive = 'active';
  static const String statusPaused = 'paused';
  static const String statusCompleted = 'completed';
  static const String statusFailed = 'failed';

  // Task type constants
  static const String typeInterval = 'interval';
  static const String typeCron = 'cron';
  static const String typeOnce = 'once';

  // Execution target constants
  static const String targetAgent = 'agent';
  static const String targetGroup = 'group';

  // Sentinel used in copyWith to distinguish "set to null" from "keep current".
  static const Object _sentinel = Object();

  const ScheduledTask({
    required this.id,
    this.agentId,
    this.channelId,
    required this.taskType,
    required this.description,
    required this.status,
    required this.instruction,
    this.parameters,
    required this.schedulePattern,
    this.lastRunAt,
    required this.nextRunAt,
    required this.executionCount,
    required this.failureCount,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
    required this.createdBy,
    this.executionTarget = targetAgent,
    this.agentIds = const [],
    this.mentionedAgentIds = const [],
  });

  /// Create a ScheduledTask from a JSON map (typically from database).
  factory ScheduledTask.fromJson(Map<String, dynamic> json) {
    return ScheduledTask(
      id: json['id'] as String,
      agentId: json['agent_id'] as String?,
      channelId: json['channel_id'] as String?,
      taskType: json['task_type'] as String,
      description: json['description'] as String? ?? '',
      status: json['status'] as String? ?? statusPending,
      instruction: json['instruction'] as String,
      parameters: json['parameters'] != null
          ? jsonDecode(json['parameters'] as String) as Map<String, dynamic>
          : null,
      schedulePattern: json['schedule_pattern'] as String,
      lastRunAt: json['last_run_at'] as int?,
      nextRunAt: json['next_run_at'] as int,
      executionCount: json['execution_count'] as int? ?? 0,
      failureCount: json['failure_count'] as int? ?? 0,
      lastError: json['last_error'] as String?,
      createdAt: json['created_at'] as int,
      updatedAt: json['updated_at'] as int,
      createdBy: json['created_by'] as String,
      executionTarget: json['execution_target'] as String? ?? targetAgent,
      agentIds: _parseStringList(json['agent_ids']),
      mentionedAgentIds: _parseStringList(json['mentioned_agent_ids']),
    );
  }

  /// Convert ScheduledTask to a JSON map (typically for database storage).
  Map<String, dynamic> toJson() => {
    'id': id,
    'agent_id': agentId,
    'channel_id': channelId,
    'task_type': taskType,
    'description': description,
    'status': status,
    'instruction': instruction,
    'parameters': parameters != null ? jsonEncode(parameters) : null,
    'schedule_pattern': schedulePattern,
    'last_run_at': lastRunAt,
    'next_run_at': nextRunAt,
    'execution_count': executionCount,
    'failure_count': failureCount,
    'last_error': lastError,
    'created_at': createdAt,
    'updated_at': updatedAt,
    'created_by': createdBy,
    'execution_target': executionTarget,
    'agent_ids': agentIds.isEmpty ? null : jsonEncode(agentIds),
    'mentioned_agent_ids': mentionedAgentIds.isEmpty ? null : jsonEncode(mentionedAgentIds),
  };

  /// Create a copy of this task with some fields replaced.
  ///
  /// To set [agentId] to null, pass `agentId: null` explicitly.
  /// To keep the current value, omit the parameter.
  ScheduledTask copyWith({
    String? id,
    Object? agentId = _sentinel,
    String? channelId,
    String? taskType,
    String? description,
    String? status,
    String? instruction,
    Map<String, dynamic>? parameters,
    String? schedulePattern,
    int? lastRunAt,
    int? nextRunAt,
    int? executionCount,
    int? failureCount,
    String? lastError,
    int? createdAt,
    int? updatedAt,
    String? createdBy,
    String? executionTarget,
    List<String>? agentIds,
    List<String>? mentionedAgentIds,
  }) {
    return ScheduledTask(
      id: id ?? this.id,
      agentId: identical(agentId, _sentinel) ? this.agentId : agentId as String?,
      channelId: channelId ?? this.channelId,
      taskType: taskType ?? this.taskType,
      description: description ?? this.description,
      status: status ?? this.status,
      instruction: instruction ?? this.instruction,
      parameters: parameters ?? this.parameters,
      schedulePattern: schedulePattern ?? this.schedulePattern,
      lastRunAt: lastRunAt ?? this.lastRunAt,
      nextRunAt: nextRunAt ?? this.nextRunAt,
      executionCount: executionCount ?? this.executionCount,
      failureCount: failureCount ?? this.failureCount,
      lastError: lastError ?? this.lastError,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      createdBy: createdBy ?? this.createdBy,
      executionTarget: executionTarget ?? this.executionTarget,
      agentIds: agentIds ?? this.agentIds,
      mentionedAgentIds: mentionedAgentIds ?? this.mentionedAgentIds,
    );
  }

  static List<String> _parseStringList(dynamic value) {
    if (value == null) return const [];
    if (value is List) return value.cast<String>();
    try {
      final decoded = jsonDecode(value as String);
      if (decoded is List) return decoded.cast<String>();
    } catch (_) {}
    return const [];
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScheduledTask && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() =>
      'ScheduledTask(id: $id, agentId: $agentId, target: $executionTarget, description: $description, status: $status, nextRunAt: $nextRunAt)';
}

import 'dart:async';
import 'package:uuid/uuid.dart';

import '../helpers/cron_parser.dart';
import '../models/scheduled_task.dart';
import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import 'agent_task_executor.dart';
import 'group_task_executor.dart';

/// Manages scheduled task execution with support for cron and interval schedules.
/// 
/// The service maintains in-memory timers for active tasks and automatically
/// reschedules them based on their patterns (cron, interval, or one-time).
/// 
/// Usage:
/// ```dart
/// // Initialize at app startup
/// await ScheduledTaskService().startScheduler();
/// 
/// // Create a task
/// final task = await ScheduledTaskService().createScheduledTask(
///   agentId: 'agent-123',
///   instruction: 'Check system health',
///   schedulePattern: '0 9 * * *',  // 9am daily
/// );
/// 
/// // Activate the task
/// await ScheduledTaskService().activateScheduledTask(task.id);
/// 
/// // Pause all when app goes to background
/// await ScheduledTaskService().pauseScheduler();
/// 
/// // Resume when app comes to foreground
/// await ScheduledTaskService().resumeScheduler();
/// ```
class ScheduledTaskService {
  static final ScheduledTaskService _instance = ScheduledTaskService._();
  factory ScheduledTaskService() => _instance;
  ScheduledTaskService._();

  final LocalDatabaseService _db = LocalDatabaseService();
  final Uuid _uuid = const Uuid();

  // Timers for each scheduled task (keyed by task ID)
  final Map<String, Timer> _timers = {};

  bool _initialized = false;
  bool _running = false;

  bool get isRunning => _running;

  /// Start the scheduler and resume all active tasks.
  /// 
  /// Should be called once during app initialization.
  Future<void> startScheduler() async {
    if (_initialized) return;
    _initialized = true;
    _running = true;

    LoggerService().info('Starting scheduled task service', tag: 'ScheduledTasks');

    final activeTasks = await _db.listScheduledTasks(status: ScheduledTask.statusActive);

    for (final task in activeTasks) {
      await _scheduleTask(task);
    }
  }

  /// Pause all active tasks without losing their state.
  /// 
  /// Call this when the app goes to the background.
  Future<void> pauseScheduler() async {
    _running = false;
    _cancelAllTimers();
    LoggerService().info('Scheduled task service paused', tag: 'ScheduledTasks');
  }

  /// Resume all active tasks after being paused.
  /// 
  /// Call this when the app comes back to the foreground.
  Future<void> resumeScheduler() async {
    if (!_initialized) await startScheduler();
    _running = true;

    final activeTasks = await _db.listScheduledTasks(status: ScheduledTask.statusActive);
    for (final task in activeTasks) {
      await _scheduleTask(task);
    }

    LoggerService().info('Scheduled task service resumed', tag: 'ScheduledTasks');
  }

  /// Create a new scheduled task.
  ///
  /// The task is created in 'pending' status and must be activated to start executing.
  ///
  /// Parameters:
  /// - [agentId]: The agent to execute the task for (required for agent tasks, null for group tasks)
  /// - [instruction]: The task instruction/prompt to execute
  /// - [schedulePattern]: Cron expression (e.g., "0 9 * * *") or ISO 8601 duration (e.g., "PT5M")
  /// - [channelId]: Required for group tasks; optional DM channel override for agent tasks
  /// - [description]: Human-readable description of the task
  /// - [parameters]: Optional task-specific configuration
  /// - [createdBy]: User ID who created the task
  /// - [executionTarget]: 'agent' (default) or 'group'
  /// - [agentIds]: Group task: list of participating agent IDs
  /// - [mentionedAgentIds]: Group task: subset of agents to @-mention
  Future<ScheduledTask> createScheduledTask({
    String? agentId,
    required String instruction,
    required String schedulePattern,
    String? channelId,
    String? description,
    Map<String, dynamic>? parameters,
    String createdBy = 'user',
    String executionTarget = ScheduledTask.targetAgent,
    List<String> agentIds = const [],
    List<String> mentionedAgentIds = const [],
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final nextRunAt = _calculateNextRun(schedulePattern, now) ?? 0;
    final taskType = _getTaskType(schedulePattern);

    final task = ScheduledTask(
      id: _uuid.v4(),
      agentId: agentId,
      channelId: channelId,
      taskType: taskType,
      description: description ?? instruction,
      status: ScheduledTask.statusPending,
      instruction: instruction,
      parameters: parameters,
      schedulePattern: schedulePattern,
      lastRunAt: null,
      nextRunAt: nextRunAt,
      executionCount: 0,
      failureCount: 0,
      lastError: null,
      createdAt: now,
      updatedAt: now,
      createdBy: createdBy,
      executionTarget: executionTarget,
      agentIds: agentIds,
      mentionedAgentIds: mentionedAgentIds,
    );

    await _db.createScheduledTask(task);
    LoggerService().info('Created scheduled task: ${task.id}', tag: 'ScheduledTasks');

    return task;
  }

  /// Activate a scheduled task (start scheduling).
  /// 
  /// Changes status from 'pending' to 'active' and begins executing according to schedule.
  Future<void> activateScheduledTask(String taskId) async {
    final task = await _db.getScheduledTaskById(taskId);
    if (task == null) throw Exception('Task not found: $taskId');

    final updated = task.copyWith(
      status: ScheduledTask.statusActive,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.updateScheduledTask(updated);

    if (_running) {
      await _scheduleTask(updated);
    }

    LoggerService().info('Activated scheduled task: $taskId', tag: 'ScheduledTasks');
  }

  /// Pause a scheduled task (stop scheduling but keep it).
  /// 
  /// Changes status to 'paused' and stops execution. Can be resumed later.
  Future<void> pauseScheduledTask(String taskId) async {
    final task = await _db.getScheduledTaskById(taskId);
    if (task == null) throw Exception('Task not found: $taskId');

    _cancelTaskTimer(taskId);

    final updated = task.copyWith(
      status: ScheduledTask.statusPaused,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await _db.updateScheduledTask(updated);

    LoggerService().info('Paused scheduled task: $taskId', tag: 'ScheduledTasks');
  }

  /// Delete a scheduled task permanently.
  /// 
  /// Cancels any active timers and removes from database.
  Future<void> deleteScheduledTask(String taskId) async {
    _cancelTaskTimer(taskId);
    await _db.deleteScheduledTask(taskId);
    LoggerService().info('Deleted scheduled task: $taskId', tag: 'ScheduledTasks');
  }

  /// Get all scheduled tasks for an agent.
  Future<List<ScheduledTask>> listTasksForAgent(String agentId) async {
    return await _db.listScheduledTasks(agentId: agentId);
  }

  /// Get all active scheduled tasks.
  Future<List<ScheduledTask>> listActiveTasks() async {
    return await _db.listScheduledTasks(status: ScheduledTask.statusActive);
  }

  /// Get a specific scheduled task by ID.
  Future<ScheduledTask?> getTask(String taskId) async {
    return await _db.getScheduledTaskById(taskId);
  }

  /// Execute a scheduled task immediately (regardless of schedule).
  Future<void> executeTaskNow(String taskId) async {
    final task = await _db.getScheduledTaskById(taskId);
    if (task == null) throw Exception('Task not found: $taskId');

    await _executeTask(task);
  }

  /// Update a scheduled task.
  Future<void> updateScheduledTask(ScheduledTask task) async {
    await _db.updateScheduledTask(task.copyWith(
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }

  // ── Private helpers ──

  Future<void> _scheduleTask(ScheduledTask task) async {
    if (!_running || task.status != ScheduledTask.statusActive) return;

    final taskType = task.taskType;

    if (taskType == ScheduledTask.typeInterval) {
      _scheduleIntervalTask(task);
    } else if (taskType == ScheduledTask.typeCron) {
      _scheduleCronTask(task);
    } else if (taskType == ScheduledTask.typeOnce) {
      _scheduleOnceTask(task);
    }
  }

  void _scheduleIntervalTask(ScheduledTask task) {
    try {
      // Parse ISO 8601 duration: PT5M, PT1H, etc.
      final duration = CronParser.parseIsoDuration(task.schedulePattern);
      if (duration == null) {
        LoggerService().error(
          'Failed to parse interval duration: ${task.schedulePattern}',
          tag: 'ScheduledTasks',
        );
        return;
      }

      final timer = Timer.periodic(duration, (_) async {
        if (!_running) return;
        // Re-fetch latest task to get current status and counts.
        final latestTask = await _db.getScheduledTaskById(task.id);
        if (latestTask == null || latestTask.status != ScheduledTask.statusActive) {
          _cancelTaskTimer(task.id);
          return;
        }
        await _executeTask(latestTask);
      });

      _timers[task.id] = timer;
      LoggerService().debug(
        'Scheduled interval task: ${task.id} -> ${task.schedulePattern}',
        tag: 'ScheduledTasks',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to schedule interval task',
        tag: 'ScheduledTasks',
        error: e,
      );
    }
  }

  void _scheduleCronTask(ScheduledTask task) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      // Always compute delay from current time to avoid stale nextRunAt causing
      // an infinite synchronous recursion (task.nextRunAt may already be past
      // if this is a re-schedule after execution).
      final rawNext = task.nextRunAt > now
          ? task.nextRunAt
          : _calculateNextRun(task.schedulePattern, now);

      // Guard: if the cron expression is invalid, _calculateNextRun returns null.
      // Abort scheduling rather than firing immediately or crashing.
      if (rawNext == null) {
        LoggerService().error(
          'Invalid cron expression for task ${task.id}: "${task.schedulePattern}" — task will not be scheduled',
          tag: 'ScheduledTasks',
        );
        return;
      }

      final delay = rawNext - now;

      // Use at least 1 second to prevent accidental tight loops.
      final safeDuration = Duration(milliseconds: delay < 1000 ? 1000 : delay);

      final timer = Timer(safeDuration, () async {
        if (!_running) return;

        // Re-fetch task to ensure we have the latest status and counts.
        final latestTask = await _db.getScheduledTaskById(task.id);
        if (latestTask == null || latestTask.status != ScheduledTask.statusActive) {
          _timers.remove(task.id);
          return;
        }

        await _executeTask(latestTask);

        // Reschedule only if the task is still tracked (not deleted/cancelled).
        if (_running && _timers.containsKey(task.id)) {
          // Re-fetch again so we schedule from the updated nextRunAt.
          final refreshed = await _db.getScheduledTaskById(task.id);
          if (refreshed != null && refreshed.status == ScheduledTask.statusActive) {
            _scheduleCronTask(refreshed);
          } else {
            _timers.remove(task.id);
          }
        }
      });

      _timers[task.id] = timer;
      LoggerService().debug(
        'Scheduled cron task: ${task.id} -> next run in ${safeDuration.inSeconds}s',
        tag: 'ScheduledTasks',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to schedule cron task',
        tag: 'ScheduledTasks',
        error: e,
      );
    }
  }

  void _scheduleOnceTask(ScheduledTask task) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;

      // Guard: nextRunAt must be a valid future timestamp.
      // A value of 0 means the schedulePattern couldn't be parsed —
      // do not execute; mark the task as failed instead.
      if (task.nextRunAt <= 0) {
        LoggerService().error(
          'One-time task ${task.id} has invalid nextRunAt (${task.nextRunAt}), aborting scheduling',
          tag: 'ScheduledTasks',
        );
        _db.updateScheduledTask(task.copyWith(
          status: ScheduledTask.statusCompleted,
          lastError: 'Invalid schedule: nextRunAt is not set',
          updatedAt: now,
        ));
        return;
      }

      final delay = task.nextRunAt - now;

      // If already past due by more than 60 seconds, treat as missed — mark
      // completed without re-executing to avoid surprise late triggers.
      if (delay < -60000) {
        LoggerService().info(
          'One-time task ${task.id} is past due, marking completed without execution',
          tag: 'ScheduledTasks',
        );
        _db.updateScheduledTask(task.copyWith(
          status: ScheduledTask.statusCompleted,
          updatedAt: now,
        ));
        return;
      }

      final safeDuration = Duration(milliseconds: delay < 0 ? 0 : delay);

      final timer = Timer(safeDuration, () async {
        if (!_running) return;
        final latestTask = await _db.getScheduledTaskById(task.id);
        if (latestTask == null || latestTask.status != ScheduledTask.statusActive) {
          _timers.remove(task.id);
          return;
        }
        await _executeTask(latestTask);
        _timers.remove(task.id);
      });

      _timers[task.id] = timer;
      LoggerService().debug(
        'Scheduled one-time task: ${task.id} at ${DateTime.fromMillisecondsSinceEpoch(task.nextRunAt)}',
        tag: 'ScheduledTasks',
      );
    } catch (e) {
      LoggerService().error(
        'Failed to schedule one-time task',
        tag: 'ScheduledTasks',
        error: e,
      );
    }
  }

  Future<void> _executeTask(ScheduledTask task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    LoggerService().info(
      'Executing scheduled task: ${task.id} (${task.description})',
      tag: 'ScheduledTasks',
    );

    try {
      // Delegate to the appropriate executor based on the task's execution target.
      final executor = task.executionTarget == ScheduledTask.targetGroup
          ? GroupTaskExecutor()
          : AgentTaskExecutor();
      await executor.execute(task);

      // One-time tasks are marked completed after execution.
      final isOnce = task.taskType == ScheduledTask.typeOnce;
      final updated = task.copyWith(
        lastRunAt: now,
        executionCount: task.executionCount + 1,
        status: isOnce ? ScheduledTask.statusCompleted : task.status,
        nextRunAt: isOnce ? task.nextRunAt : (_calculateNextRun(task.schedulePattern, now) ?? task.nextRunAt),
        updatedAt: now,
        lastError: null,
      );
      await _db.updateScheduledTask(updated);
      if (isOnce) _cancelTaskTimer(task.id);

      LoggerService().info(
        'Scheduled task executed successfully: ${task.id}',
        tag: 'ScheduledTasks',
      );
    } catch (execError) {
      // Update task with failure information
      final updated = task.copyWith(
        lastRunAt: now,
        failureCount: task.failureCount + 1,
        lastError: execError.toString(),
        nextRunAt: _calculateNextRun(task.schedulePattern, now) ?? task.nextRunAt,
        updatedAt: now,
      );
      await _db.updateScheduledTask(updated);

      LoggerService().error(
        'Scheduled task execution failed: ${task.id}',
        tag: 'ScheduledTasks',
        error: execError,
      );
    }
  }

  /// Get the task type from a schedule pattern.
  String _getTaskType(String pattern) {
    // One-time task: pattern is a millisecond timestamp (pure integer string)
    if (int.tryParse(pattern) != null) {
      return ScheduledTask.typeOnce;
    }

    // Check if it's ISO 8601 duration (PT...)
    if (pattern.toUpperCase().startsWith('P')) {
      return ScheduledTask.typeInterval;
    }

    // Cron expression (5 space-separated fields)
    if (pattern.split(RegExp(r'\s+')).length == 5 ||
        CronParser.isValidCron(pattern)) {
      return ScheduledTask.typeCron;
    }

    // Default to cron for backward compatibility
    return ScheduledTask.typeCron;
  }

  /// Calculate the next run time based on the schedule pattern.
  ///
  /// Returns the next fire timestamp in milliseconds, or `null` if the pattern
  /// is invalid and no next time can be determined.
  int? _calculateNextRun(String schedulePattern, int fromTime) {
    // One-time task: pattern is a raw millisecond timestamp (pure integer string).
    // Do NOT feed it into the cron parser.
    if (int.tryParse(schedulePattern) != null) {
      return int.parse(schedulePattern);
    }

    if (schedulePattern.toUpperCase().startsWith('P')) {
      // ISO 8601 duration
      final duration = CronParser.parseIsoDuration(schedulePattern);
      if (duration == null) return null;
      return CronParser.calculateNextIntervalRun(duration, fromTime: fromTime);
    } else {
      // Cron expression — returns null when invalid, never falls back to now.
      return CronParser.calculateNextCronRun(schedulePattern, fromTime: fromTime);
    }
  }

  void _cancelTaskTimer(String taskId) {
    final timer = _timers.remove(taskId);
    timer?.cancel();
  }

  void _cancelAllTimers() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
  }
}

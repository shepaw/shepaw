# 关键代码片段速查

## 1️⃣ 应用启动初始化

### 文件: `lib/main.dart` (第 118 行)
```dart
// Initialize scheduled task service
await ScheduledTaskService().startScheduler();
```

---

## 2️⃣ 启动调度器逻辑

### 文件: `lib/task/services/scheduled_task_service.dart` (第 56-68 行)
```dart
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
```

---

## 3️⃣ 创建定时任务

### 文件: `lib/task/services/scheduled_task_service.dart` (第 109-152 行)
```dart
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
  final nextRunAt = _calculateNextRun(schedulePattern, now);  // 🔴 关键：计算下次运行时间
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
```

---

## 4️⃣ 激活任务（立即注册定时器）

### 文件: `lib/task/services/scheduled_task_service.dart` (第 157-172 行)
```dart
Future<void> activateScheduledTask(String taskId) async {
  final task = await _db.getScheduledTaskById(taskId);
  if (task == null) throw Exception('Task not found: $taskId');

  final updated = task.copyWith(
    status: ScheduledTask.statusActive,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
  await _db.updateScheduledTask(updated);

  if (_running) {
    await _scheduleTask(updated);  // 🔴 立即注册定时器！
  }

  LoggerService().info('Activated scheduled task: $taskId', tag: 'ScheduledTasks');
}
```

---

## 5️⃣ Cron 任务调度（⭐ 最重要）

### 文件: `lib/task/services/scheduled_task_service.dart` (第 284-334 行)
```dart
void _scheduleCronTask(ScheduledTask task) {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 🔴 计算延迟时间
    // 问题：如果 task.nextRunAt 已经很接近 now，延迟会非常短！
    final nextRunMs = task.nextRunAt > now
        ? task.nextRunAt
        : _calculateNextRun(task.schedulePattern, now);
    final delay = nextRunMs - now;

    // 使用最少 1 秒的延迟（但如果本来就接近，这也解决不了）
    final safeDuration = Duration(milliseconds: delay < 1000 ? 1000 : delay);

    final timer = Timer(safeDuration, () async {
      if (!_running) return;

      // Re-fetch task to ensure we have the latest status and counts.
      final latestTask = await _db.getScheduledTaskById(task.id);
      if (latestTask == null || latestTask.status != ScheduledTask.statusActive) {
        _timers.remove(task.id);
        return;
      }

      await _executeTask(latestTask);  // 🔴 执行任务

      // Reschedule only if the task is still tracked (not deleted/cancelled).
      if (_running && _timers.containsKey(task.id)) {
        // Re-fetch again so we schedule from the updated nextRunAt.
        final refreshed = await _db.getScheduledTaskById(task.id);
        if (refreshed != null && refreshed.status == ScheduledTask.statusActive) {
          _scheduleCronTask(refreshed);  // 递归重新调度
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
```

---

## 6️⃣ Interval 任务调度

### 文件: `lib/task/services/scheduled_task_service.dart` (第 247-282 行)
```dart
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

    // 🟢 使用 Timer.periodic 周期执行（不同于 Cron）
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
```

---

## 7️⃣ 任务执行逻辑

### 文件: `lib/task/services/scheduled_task_service.dart` (第 382-430 行)
```dart
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
    await executor.execute(task);  // 🔴 调用执行器

    // One-time tasks are marked completed after execution.
    final isOnce = task.taskType == ScheduledTask.typeOnce;
    final updated = task.copyWith(
      lastRunAt: now,
      executionCount: task.executionCount + 1,
      status: isOnce ? ScheduledTask.statusCompleted : task.status,
      nextRunAt: isOnce ? task.nextRunAt : _calculateNextRun(task.schedulePattern, now),
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
      nextRunAt: _calculateNextRun(task.schedulePattern, now),
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
```

---

## 8️⃣ 立即执行任务

### 文件: `lib/task/screens/scheduled_tasks_management_screen.dart` (第 281-291 行)
```dart
Future<void> _executeTaskNow(BuildContext context, ScheduledTask task, AppLocalizations l10n) async {
  // 🔴 Fire-and-forget: 不等待完整的 agent 执行，仅发起分发
  _taskService.executeTaskNow(task.id).catchError((e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  });
  // 🔴 立即显示成功提示（不等待任务完成）
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduledTasks_executeNowSuccess)));
  }
}
```

### 文件: `lib/task/services/scheduled_task_service.dart` (第 216-222 行)
```dart
Future<void> executeTaskNow(String taskId) async {
  final task = await _db.getScheduledTaskById(taskId);
  if (task == null) throw Exception('Task not found: $taskId');

  await _executeTask(task);  // 直接调用 _executeTask
}
```

---

## 9️⃣ Agent 执行器

### 文件: `lib/task/services/agent_task_executor.dart` (第 11-37 行)
```dart
Future<void> execute(ScheduledTask task) async {
  if (task.agentId == null) {
    throw Exception('AgentTaskExecutor: task.agentId is null for task ${task.id}');
  }

  final db = LocalDatabaseService();
  final tokenService = TokenService(db);
  final agentService = RemoteAgentService(db, tokenService);
  final agent = await agentService.getAgentById(task.agentId!);

  if (agent == null) {
    throw Exception('Agent not found: ${task.agentId}');
  }

  // Determine channel: use the task's channelId if set, otherwise let
  // ChatService create/reuse the default DM session for this agent.
  final channelId =
      (task.channelId != null && task.channelId!.isNotEmpty) ? task.channelId : null;

  // 🔴 异步发送指令给 Agent
  await ChatService().sendMessageToAgent(
    content: task.instruction,
    agent: agent,
    userId: 'user',
    userName: 'User',
    channelId: channelId,
  );
}
```

---

## 🔟 Cron 表达式计算

### 文件: `lib/task/helpers/cron_parser.dart` (第 60-93 行)
```dart
static int calculateNextCronRun(String cronExpression, {int? fromTime}) {
  fromTime ??= DateTime.now().millisecondsSinceEpoch;
  final from = DateTime.fromMillisecondsSinceEpoch(fromTime);

  final parts = cronExpression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return fromTime;

  final minute = parts[0];
  final hour = parts[1];
  final dayOfMonth = parts[2];
  final month = parts[3];
  final dayOfWeek = parts[4];

  // 🔴 Start from next minute（这会导致问题！）
  var next = DateTime(from.year, from.month, from.day, from.hour, from.minute)
      .add(const Duration(minutes: 1));

  // Search for next valid time (up to 4 years in the future as a safety limit)
  final maxTime = DateTime.now().add(Duration(days: 4 * 365));

  while (next.isBefore(maxTime)) {
    if (_matchesCronPart(next.minute, minute) &&
        _matchesCronPart(next.hour, hour) &&
        _matchesCronPart(next.day, dayOfMonth) &&
        _matchesCronPart(next.month, month) &&
        _matchesCronDayOfWeek(next.weekday, dayOfWeek)) {
      return next.millisecondsSinceEpoch;
    }
    next = next.add(const Duration(minutes: 1));  // 每分钟扫一遍
  }

  // Fallback: return 1 hour from now
  return from.add(const Duration(hours: 1)).millisecondsSinceEpoch;
}
```

---

## 1️⃣1️⃣ Cron 表达式生成

### 文件: `lib/task/screens/scheduled_task_form_screen.dart` (第 280-299 行)
```dart
String _buildCronExpression() {
  final m = _cronMinute.toString().padLeft(2, '0');
  final h = _cronHour.toString();
  switch (_cronFrequency) {
    case _CronFrequency.daily:
      return '$m $h * * *';  // 例: "00 09 * * *"
    case _CronFrequency.weekly:
      if (_cronWeekdays.isEmpty) return '$m $h * * *';
      final days =
          (_cronWeekdays.toList()..sort()).map((d) => d.toString()).join(',');
      return '$m $h * * $days';  // 例: "00 09 * * 1,2,3,4,5"
    case _CronFrequency.monthly:
      if (_cronMonthdays.isEmpty) return '$m $h 1 * *';
      final days =
          (_cronMonthdays.toList()..sort()).map((d) => d.toString()).join(',');
      return '$m $h $days * *';  // 例: "00 09 1 * *"
    case _CronFrequency.custom:
      return _cronCustomController.text.trim();
  }
}
```

---

## 1️⃣2️⃣ Cron 表达式验证

### 文件: `lib/task/helpers/cron_parser.dart` (第 10-19 行)
```dart
static bool isValidCron(String cron) {
  final parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return false;  // 必须是 5 个字段

  // Check each part is either * or a number/range/list
  for (final part in parts) {
    if (!_isValidCronPart(part)) return false;
  }
  return true;
}
```

---

## 1️⃣3️⃣ App 生命周期管理

### 文件: `lib/services/app_lifecycle_service.dart` (第 50-67 行)
```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  isInForeground = state == AppLifecycleState.resumed;

  if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
    // Record when the app entered background (only on the first transition).
    _backgroundedAtMs ??= DateTime.now().millisecondsSinceEpoch;
    // 🔴 暂停定时任务
    ScheduledTaskService().pauseScheduler();
  } else if (state == AppLifecycleState.resumed && _backgroundedAtMs != null) {
    final duration = Duration(
      milliseconds: DateTime.now().millisecondsSinceEpoch - _backgroundedAtMs!,
    );
    _backgroundedAtMs = null;
    _onResumeController.add(duration);
    // 🟢 恢复定时任务
    ScheduledTaskService().resumeScheduler();
  }
}
```

---

## 1️⃣4️⃣ 数据库创建任务

### 文件: `lib/services/local_database_service.dart` (第 1408-1415 行)
```dart
Future<void> createScheduledTask(ScheduledTask task) async {
  final db = await database;
  await db.insert(
    'scheduled_tasks',
    task.toJson(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}
```

---

## 1️⃣5️⃣ 数据库查询任务

### 文件: `lib/services/local_database_service.dart` (第 1418-1426 行)
```dart
Future<ScheduledTask?> getScheduledTaskById(String id) async {
  final db = await database;
  final results = await db.query(
    'scheduled_tasks',
    where: 'id = ?',
    whereArgs: [id],
  );
  return results.isEmpty ? null : ScheduledTask.fromJson(results.first);
}
```

---

## 问题根源总结

| 问题 | 文件 | 行号 | 原因 |
|------|------|------|------|
| **Cron 计算过近** | cron_parser.dart | 74 | 从"下一分钟"开始搜索 |
| **立即激活定时器** | scheduled_task_service.dart | 168 | activateScheduledTask 立即调用 _scheduleTask |
| **最小延迟不足** | scheduled_task_service.dart | 296 | 只保证 1 秒最小延迟 |
| **立即显示提示** | scheduled_tasks_management_screen.dart | 289 | Fire-and-forget 立即显示成功提示 |


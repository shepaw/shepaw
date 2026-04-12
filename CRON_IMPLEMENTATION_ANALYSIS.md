# CronCreate / 定时任务系统 - 完整分析报告

## 🔍 核心实现文件与关键代码

### 1. **Cron 表达式解析与验证** 
**文件**: `lib/task/helpers/cron_parser.dart` (305行)

#### A. Cron 表达式验证 (第10-19行)
```dart
static bool isValidCron(String cron) {
  final parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return false;

  // Check each part is either * or a number/range/list
  for (final part in parts) {
    if (!_isValidCronPart(part)) return false;
  }
  return true;
}
```

#### B. Cron 单部分验证 (第278-303行)
```dart
static bool _isValidCronPart(String part) {
  if (part == '*') return true;

  // Handle step values
  if (part.contains('/')) {
    final stepStr = part.split('/').last;
    return int.tryParse(stepStr) != null;
  }

  // Handle ranges
  if (part.contains('-')) {
    final rangeParts = part.split('-');
    if (rangeParts.length != 2) return false;
    return int.tryParse(rangeParts[0]) != null && int.tryParse(rangeParts[1]) != null;
  }

  // Handle lists
  if (part.contains(',')) {
    final values = part.split(',');
    return values.every((v) => int.tryParse(v.trim()) != null);
  }

  // Single number
  return int.tryParse(part) != null;
}
```

#### C. ISO 8601 Duration 解析 (第29-54行)
```dart
static Duration? parseIsoDuration(String durationStr) {
  try {
    // ISO 8601 duration pattern: P[n]D[T[n]H[n]M[n]S]
    final pattern = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    );

    final match = pattern.firstMatch(durationStr.toUpperCase());
    if (match == null) return null;

    final days = int.tryParse(match.group(1) ?? '0') ?? 0;
    final hours = int.tryParse(match.group(2) ?? '0') ?? 0;
    final minutes = int.tryParse(match.group(3) ?? '0') ?? 0;
    final seconds = double.tryParse(match.group(4) ?? '0') ?? 0;

    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      seconds: seconds.toInt(),
      milliseconds: ((seconds % 1) * 1000).toInt(),
    );
  } catch (e) {
    return null;
  }
}
```

#### D. 下次执行时间计算 (第60-93行) ⚠️ **Invalid Fallback**
```dart
static int calculateNextCronRun(String cronExpression, {int? fromTime}) {
  fromTime ??= DateTime.now().millisecondsSinceEpoch;
  final from = DateTime.fromMillisecondsSinceEpoch(fromTime);

  final parts = cronExpression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return fromTime;  // ❌ 无效 cron 返回当前时间

  final minute = parts[0];
  final hour = parts[1];
  final dayOfMonth = parts[2];
  final month = parts[3];
  final dayOfWeek = parts[4];

  // Start from next minute
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
    next = next.add(const Duration(minutes: 1));
  }

  // ✅ FALLBACK: 返回 1 小时后 (如果找不到有效的下次执行时间)
  return from.add(const Duration(hours: 1)).millisecondsSinceEpoch;
}
```

#### E. Cron 部分匹配 (第198-234行)
```dart
static bool _matchesCronPart(int value, String pattern) {
  if (pattern == '*') return true;

  // Handle step values (*/n or start-end/n)
  if (pattern.contains('/')) {
    final parts = pattern.split('/');
    final step = int.tryParse(parts[1]) ?? 1;

    if (parts[0] == '*') {
      return value % step == 0;
    } else if (parts[0].contains('-')) {
      final rangeParts = parts[0].split('-');
      final start = int.tryParse(rangeParts[0]) ?? 0;
      final end = int.tryParse(rangeParts[1]) ?? 59;
      return value >= start && value <= end && (value - start) % step == 0;
    }
    return value % step == 0;
  }

  // Handle ranges
  if (pattern.contains('-')) {
    final parts = pattern.split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final end = int.tryParse(parts[1]) ?? 59;
    return value >= start && value <= end;
  }

  // Handle lists
  if (pattern.contains(',')) {
    final values = pattern.split(',').map((s) => int.tryParse(s.trim()) ?? -1).toList();
    return values.contains(value);
  }

  // Handle single value
  final singleValue = int.tryParse(pattern);
  return singleValue != null && singleValue == value;
}
```

#### F. 周几匹配 (第240-276行)
```dart
static bool _matchesCronDayOfWeek(int dateTimeWeekday, String pattern) {
  if (pattern == '*') return true;

  // Convert DateTime weekday (1=Mon, 7=Sun) to cron format (0=Sun, 1=Mon, ..., 6=Sat)
  int cronWeekday = dateTimeWeekday == 7 ? 0 : dateTimeWeekday;

  // Handle step values
  if (pattern.contains('/')) {
    final parts = pattern.split('/');
    final step = int.tryParse(parts[1]) ?? 1;
    return cronWeekday % step == 0;
  }

  // Handle ranges (may wrap around, e.g., "5-1" means Fri-Mon)
  if (pattern.contains('-')) {
    final parts = pattern.split('-');
    final start = int.tryParse(parts[0]) ?? 0;
    final end = int.tryParse(parts[1]) ?? 6;

    if (start <= end) {
      return cronWeekday >= start && cronWeekday <= end;
    } else {
      // Wrap around (e.g., 5-1 = Fri, Sat, Sun, Mon)
      return cronWeekday >= start || cronWeekday <= end;
    }
  }

  // Handle lists
  if (pattern.contains(',')) {
    final values = pattern.split(',').map((s) => int.tryParse(s.trim()) ?? -1).toList();
    return values.contains(cronWeekday);
  }

  // Handle single value
  final singleValue = int.tryParse(pattern);
  return singleValue != null && (singleValue == cronWeekday || (singleValue == 7 && cronWeekday == 0));
}
```

---

### 2. **定时任务数据模型**
**文件**: `lib/task/models/scheduled_task.dart` (207行)

#### 核心字段 (第1-40行)
```dart
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
```

#### fromJson / toJson (第84-133行)
```dart
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
```

---

### 3. **任务调度服务 - 核心执行引擎**
**文件**: `lib/task/services/scheduled_task_service.dart` (480行)

#### A. 服务初始化与生命周期 (第37-92行)
```dart
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
  Future<void> pauseScheduler() async {
    _running = false;
    _cancelAllTimers();
    LoggerService().info('Scheduled task service paused', tag: 'ScheduledTasks');
  }

  /// Resume all active tasks after being paused.
  Future<void> resumeScheduler() async {
    if (!_initialized) await startScheduler();
    _running = true;

    final activeTasks = await _db.listScheduledTasks(status: ScheduledTask.statusActive);
    for (final task in activeTasks) {
      await _scheduleTask(task);
    }

    LoggerService().info('Scheduled task service resumed', tag: 'ScheduledTasks');
  }
```

#### B. 任务创建 (第109-152行)
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
  final nextRunAt = _calculateNextRun(schedulePattern, now);
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

#### C. 任务类型检测 (第432-452行)
```dart
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
```

#### D. Cron 任务调度 (第284-334行)
```dart
void _scheduleCronTask(ScheduledTask task) {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Always compute delay from current time to avoid stale nextRunAt causing
    // an infinite synchronous recursion (task.nextRunAt may already be past
    // if this is a re-schedule after execution).
    final nextRunMs = task.nextRunAt > now
        ? task.nextRunAt
        : _calculateNextRun(task.schedulePattern, now);
    final delay = nextRunMs - now;

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
```

#### E. Interval 任务调度 (第247-282行)
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

#### F. 一次性任务调度 (第336-380行) ⚠️ **Invalid Fallback**
```dart
void _scheduleOnceTask(ScheduledTask task) {
  try {
    final now = DateTime.now().millisecondsSinceEpoch;
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
```

#### G. 任务执行 (第382-430行)
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
    await executor.execute(task);

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

#### H. 下次执行时间计算 (第454-466行)
```dart
int _calculateNextRun(String schedulePattern, int fromTime) {
  if (schedulePattern.toUpperCase().startsWith('P')) {
    // ISO 8601 duration
    return CronParser.calculateNextIntervalRun(
      CronParser.parseIsoDuration(schedulePattern)!,
      fromTime: fromTime,
    );
  } else {
    // Cron expression
    return CronParser.calculateNextCronRun(schedulePattern, fromTime: fromTime);
  }
}
```

---

### 4. **数据库层**
**文件**: `lib/services/local_database_service.dart` (1496行)

#### 数据库表定义 (第291-318行)
```dart
CREATE TABLE IF NOT EXISTS scheduled_tasks (
  id TEXT PRIMARY KEY,
  agent_id TEXT,
  channel_id TEXT,
  task_type TEXT NOT NULL,
  description TEXT,
  status TEXT DEFAULT 'pending',
  instruction TEXT NOT NULL,
  parameters TEXT,
  schedule_pattern TEXT NOT NULL,
  last_run_at INTEGER,
  next_run_at INTEGER NOT NULL,
  execution_count INTEGER DEFAULT 0,
  failure_count INTEGER DEFAULT 0,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_by TEXT NOT NULL,
  execution_target TEXT NOT NULL DEFAULT 'agent',
  agent_ids TEXT,
  mentioned_agent_ids TEXT
)
```

#### CRUD 操作 (第1408-1495行)
```dart
// 创建任务
Future<void> createScheduledTask(ScheduledTask task) async {
  final db = await database;
  await db.insert(
    'scheduled_tasks',
    task.toJson(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

// 获取任务
Future<ScheduledTask?> getScheduledTaskById(String id) async {
  final db = await database;
  final results = await db.query(
    'scheduled_tasks',
    where: 'id = ?',
    whereArgs: [id],
  );
  return results.isEmpty ? null : ScheduledTask.fromJson(results.first);
}

// 列出任务（支持筛选）
Future<List<ScheduledTask>> listScheduledTasks({
  String? agentId,
  String? status,
  String? channelId,
}) async {
  // ... implementation ...
}

// 更新任务
Future<void> updateScheduledTask(ScheduledTask task) async {
  final db = await database;
  await db.update(
    'scheduled_tasks',
    task.toJson(),
    where: 'id = ?',
    whereArgs: [task.id],
  );
}

// 删除任务
Future<void> deleteScheduledTask(String id) async {
  final db = await database;
  await db.delete(
    'scheduled_tasks',
    where: 'id = ?',
    whereArgs: [id],
  );
}
```

---

## ⚠️ Invalid Cron / Duration Fallback 行为

### 场景 1: 无效的 Cron 表达式

**关键代码位置**: `lib/task/helpers/cron_parser.dart:60-93`

```dart
static int calculateNextCronRun(String cronExpression, {int? fromTime}) {
  fromTime ??= DateTime.now().millisecondsSinceEpoch;
  final from = DateTime.fromMillisecondsSinceEpoch(fromTime);

  final parts = cronExpression.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return fromTime;  // ❌ 无效格式：返回当前时间

  // ... 寻找下次执行时间 ...
  
  // ✅ 如果找不到（四年内无匹配）
  return from.add(const Duration(hours: 1)).millisecondsSinceEpoch;  // 返回 1 小时后
}
```

**Fallback 行为**:
- **无效格式** (不是 5 个字段): 返回 `fromTime` (当前时间)，任务立即执行
- **无法匹配** (4 年内找不到匹配): 返回当前时间 + 1 小时

### 场景 2: 无效的 ISO 8601 Duration

**关键代码位置**: `lib/task/helpers/cron_parser.dart:29-54`

```dart
static Duration? parseIsoDuration(String durationStr) {
  try {
    final pattern = RegExp(
      r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$',
    );

    final match = pattern.firstMatch(durationStr.toUpperCase());
    if (match == null) return null;  // ❌ 返回 null
    
    // ... 解析 ...
  } catch (e) {
    return null;  // ❌ 异常时返回 null
  }
}
```

**Fallback 行为**:
- 调度时发现 `duration == null`: 记录错误，**不调度此任务**

**关键代码位置**: `lib/task/services/scheduled_task_service.dart:250-256`

```dart
final duration = CronParser.parseIsoDuration(task.schedulePattern);
if (duration == null) {
  LoggerService().error(
    'Failed to parse interval duration: ${task.schedulePattern}',
    tag: 'ScheduledTasks',
  );
  return;  // ❌ 任务不被调度
}
```

### 场景 3: 一次性任务过期

**关键代码位置**: `lib/task/services/scheduled_task_service.dart:343-352`

```dart
// If already past due by more than 60 seconds, treat as missed — mark
// completed without re-executing to avoid surprise late triggers.
if (delay < -60000) {  // 超过 60 秒
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
```

**Fallback 行为**:
- 一次性任务已过期 60+ 秒: **标记为完成，不执行**

---

## 📊 相关文件总结表

| 文件 | 行数 | 主要职责 |
|------|------|----------|
| `lib/task/helpers/cron_parser.dart` | 305 | Cron 表达式解析、验证、匹配计算 |
| `lib/task/models/scheduled_task.dart` | 207 | 任务数据模型、JSON 序列化 |
| `lib/task/services/scheduled_task_service.dart` | 480 | 核心调度引擎、定时器管理 |
| `lib/task/services/task_executor.dart` | 10 | 执行器接口 |
| `lib/task/services/agent_task_executor.dart` | 39 | 单Agent 执行器 |
| `lib/task/services/group_task_executor.dart` | 29 | 群组任务执行器 |
| `lib/task/screens/scheduled_task_form_screen.dart` | ~400 | 任务创建/编辑界面 |
| `lib/task/screens/scheduled_tasks_management_screen.dart` | 724 | 任务管理界面 |
| `lib/services/local_database_service.dart` | 1496 | SQLite 数据持久化 |

**总代码行数**: ~3,800 行 (主要功能模块)

---

## 🔄 执行流程图

```
┌─────────────────────────────────────────────────────────────┐
│ 应用启动 (AppLifecycleService)                              │
│ → ScheduledTaskService().startScheduler()                   │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ↓
       ┌─────────────────────────────┐
       │ 从数据库加载所有活跃任务     │
       │ (status = 'active')         │
       └────────────┬────────────────┘
                    │
         ┌──────────┴──────────┐
         ↓                     ↓
    ┌─────────┐          ┌──────────┐
    │ Cron    │          │ Interval │
    │ 任务    │          │ 任务     │
    └────┬────┘          └─────┬────┘
         │                     │
         ↓                     ↓
   _scheduleCronTask()   _scheduleIntervalTask()
   (Timer 单次)          (Timer.periodic)
         │                     │
         └──────────┬──────────┘
                    ↓
         ┌──────────────────────┐
         │ 到期时执行任务        │
         │ _executeTask()       │
         │                      │
         │ ① 获取最新任务状态   │
         │ ② 调用执行器         │
         │ ③ 更新执行计数      │
         │ ④ 计算下次执行时间   │
         └──────────┬───────────┘
                    │
         ┌──────────┴──────────┐
         ↓                     ↓
    ✅ 成功               ❌ 失败
    更新 lastRunAt       记录错误
    executionCount++    failureCount++
         │                    │
         └──────────┬────────┘
                    ↓
         ┌──────────────────────┐
         │ 重新计算下次执行时间  │
         │ _calculateNextRun()   │
         │                      │
         │ - Cron: 调用         │
         │   calculateNextCronRun()
         │ - Interval: 调用      │
         │   calculateNextIntervalRun()
         └──────────┬───────────┘
                    │
         ┌──────────┴──────────┐
         ↓                     ↓
    有效调度          无效 → Fallback
    重新计时            (见下表)
```

---

## 🎯 总结

### 核心找到的关键实现:

1. **CronCreate 工具在此系统中对应**: `ScheduledTaskService.createScheduledTask()` 
   - 创建任务时计算 `nextRunAt` (第122行)
   - 自动检测任务类型 (第123行)

2. **Cron 表达式处理**: `CronParser` 类
   - 验证: `isValidCron()` (第10-19行)
   - 计算: `calculateNextCronRun()` (第60-93行)
   - **Fallback**: 无效或无匹配时返回 1 小时后 (第92行)

3. **任务调度执行**: `ScheduledTaskService._scheduleTask()`
   - 根据类型调度: cron / interval / once (第233-245行)
   - **Invalid 处理**:
     - Invalid Duration → 不调度 (第250-257行)
     - Invalid Cron → Fallback 到 1 小时后 (由 CronParser 处理)
     - Expired Once → 标记完成不执行 (第343-352行)

4. **数据库持久化**: `LocalDatabaseService`
   - 表定义: 291-318 行
   - CRUD: 1408-1495 行


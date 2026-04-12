# Shepaw 定时任务系统 - 完整分析报告

## 📋 项目概览
**项目路径**: `/Users/edenzou/workspace/shepaw/shepaw`
**主要功能**: 支持 Cron、Interval 和 One-time 三种定时任务调度方式

---

## 🗂️ 核心文件列表

### 1. **数据模型层**
- **`lib/task/models/scheduled_task.dart`** (207 行)
  - 定时任务的数据模型定义
  - 支持三种任务类型: `cron`, `interval`, `once`
  - 支持两种执行目标: `agent`, `group`

### 2. **业务逻辑层**
- **`lib/task/services/scheduled_task_service.dart`** (480 行) ⭐ **核心服务**
  - 定时任务的创建、激活、暂停、删除
  - 定时任务的执行调度和触发
  - 三种定时方式的实现: `_scheduleIntervalTask`, `_scheduleCronTask`, `_scheduleOnceTask`

- **`lib/task/helpers/cron_parser.dart`** (304 行) ⭐ **Cron 工具库**
  - Cron 表达式的验证和解析
  - ISO 8601 duration 的解析
  - Next run time 的计算
  - Cron 表达式的人类可读描述

- **`lib/task/services/agent_task_executor.dart`** (38 行)
  - 单个 Agent 任务执行器
  - 直接发送指令给单个 Agent

- **`lib/task/services/group_task_executor.dart`** (28 行)
  - Group 频道任务执行器
  - 向 Group 频道广播指令并 @mention 特定 Agent

- **`lib/task/services/task_executor.dart`** (9 行)
  - 执行器的抽象接口

### 3. **UI 层**
- **`lib/task/screens/scheduled_task_form_screen.dart`** (1370 行)
  - 创建/编辑定时任务的完整表单界面
  - 支持 Interval、Cron、Once 三种模式的 UI 切换
  - Cron 表达式的可视化编辑和预览

- **`lib/task/screens/scheduled_tasks_management_screen.dart`** (362 行)
  - 定时任务管理界面
  - 任务列表展示、激活/暂停、立即执行、编辑、删除

### 4. **服务集成层**
- **`lib/services/app_lifecycle_service.dart`** (77 行)
  - 应用生命周期管理
  - App 进入后台时暂停定时任务
  - App 返回前台时恢复定时任务

- **`lib/services/local_database_service.dart`** (1497 行)
  - 定时任务的数据库操作 (第 1405-1495 行)
  - CRUD 操作: 创建、查询、更新、删除

- **`lib/main.dart`** (多行)
  - App 启动时初始化定时任务服务

---

## 🔄 关键工作流程

### 1️⃣ **应用启动时的初始化**

```
main.dart (第 118 行)
  ↓
ScheduledTaskService().startScheduler()  // 启动调度器
  ↓
从数据库加载所有 status='active' 的任务
  ↓
为每个任务调用 _scheduleTask()
  ↓
根据 taskType 选择合适的调度方法:
  - Cron    → _scheduleCronTask()
  - Interval → _scheduleIntervalTask()
  - Once    → _scheduleOnceTask()
```

**关键代码位置**:
- **main.dart** 第 118 行: `await ScheduledTaskService().startScheduler();`
- **scheduled_task_service.dart** 第 56-68 行: `startScheduler()` 方法

### 2️⃣ **创建新任务流程**

```
ScheduledTaskFormScreen._saveTask()  (第 346-440 行)
  ↓
验证目标、内容、时间表
  ↓
调用 ScheduledTaskService().createScheduledTask()
  (scheduled_task_service.dart 第 109-152 行)
  ↓
生成 UUID、计算 nextRunAt 时间
  ↓
保存到数据库 (_db.createScheduledTask)
  ↓
调用 activateScheduledTask()
  ↓
_scheduleTask() 注册定时器
```

**计算 nextRunAt 的逻辑**:
- **Cron**: `CronParser.calculateNextCronRun(pattern, fromTime)`
- **Interval**: `CronParser.calculateNextIntervalRun(duration, fromTime)`
- **Once**: 直接使用用户指定的 DateTime

### 3️⃣ **定时任务执行触发**

#### **Cron 类型任务** (第 284-334 行)
```dart
void _scheduleCronTask(ScheduledTask task) {
  // 1. 计算当前时间到下次运行时间的延迟
  final delay = nextRunMs - currentTimeMs
  
  // 2. 创建一次性 Timer
  Timer(safeDuration, () async {
    // 3. 执行任务
    await _executeTask(latestTask)
    
    // 4. 立即重新调度（递归）
    _scheduleCronTask(refreshed)
  })
}
```
⚠️ **注意**: 使用递归方式重新调度，而非 `Timer.periodic`

#### **Interval 类型任务** (第 247-282 行)
```dart
void _scheduleIntervalTask(ScheduledTask task) {
  // 使用 Timer.periodic 周期性执行
  Timer.periodic(duration, (_) async {
    await _executeTask(latestTask)
  })
}
```

#### **Once 类型任务** (第 336-380 行)
```dart
void _scheduleOnceTask(ScheduledTask task) {
  // 1. 一次性 Timer，执行一次后删除
  Timer(delay, () async {
    await _executeTask(latestTask)
    _timers.remove(task.id)  // 清除定时器
  })
}
```

### 4️⃣ **立即执行任务** ⭐ **关键问题所在**

**文件**: `scheduled_tasks_management_screen.dart` 第 281-291 行

```dart
Future<void> _executeTaskNow(BuildContext context, ScheduledTask task, AppLocalizations l10n) async {
  // 1. Fire-and-forget: 不等待完整的 agent 执行，仅发起分发
  _taskService.executeTaskNow(task.id).catchError((e) {
    // 错误处理
  });
  
  // 2. 立即显示成功提示（不等待任务完成）
  if (mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.scheduledTasks_executeNowSuccess)));
  }
}
```

**executeTaskNow 的实现** (scheduled_task_service.dart 第 216-222 行):
```dart
Future<void> executeTaskNow(String taskId) async {
  final task = await _db.getScheduledTaskById(taskId);
  if (task == null) throw Exception('Task not found: $taskId');
  
  await _executeTask(task);  // 直接调用 _executeTask
}
```

**_executeTask 方法** (第 382-430 行):
```dart
Future<void> _executeTask(ScheduledTask task) async {
  try {
    // 1. 选择合适的执行器 (Agent 或 Group)
    final executor = task.executionTarget == ScheduledTask.targetGroup
        ? GroupTaskExecutor()
        : AgentTaskExecutor();
    
    // 2. 执行任务 (这是异步的！)
    await executor.execute(task);
    
    // 3. 更新任务状态 (executionCount, nextRunAt, etc.)
    final updated = task.copyWith(...)
    await _db.updateScheduledTask(updated);
  } catch (execError) {
    // 错误处理和日志
  }
}
```

**AgentTaskExecutor.execute 方法** (agent_task_executor.dart 第 11-37 行):
```dart
Future<void> execute(ScheduledTask task) async {
  // 1. 获取 Agent 信息
  final agent = await agentService.getAgentById(task.agentId!);
  
  // 2. 通过 ChatService 发送消息给 Agent
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

## ⚠️ **为什么添加后立即执行？**

### 根本原因分析:

#### **原因 1: Cron 表达式计算错误**
- **位置**: `cron_parser.dart` 第 60-93 行的 `calculateNextCronRun()`
- **问题**: 从"下一分钟"开始计算，可能导致计算出的 `nextRunAt` 时间非常接近当前时间
- **现象**: 如果任务创建时间是 9:59:30，Cron 为 "0 10 * * *"（10点），计算出的 nextRunAt 可能只有几秒延迟

#### **原因 2: 激活任务后立即注册定时器**
- **位置**: `scheduled_task_service.dart` 第 157-172 行的 `activateScheduledTask()`
- **流程**:
  1. 任务创建时计算 nextRunAt
  2. 立即调用 `activateScheduledTask()`
  3. `_scheduleTask()` 立即注册定时器
  4. 如果计算出的延迟 < 1000ms，定时器会在 1-2 秒内触发

#### **原因 3: 定时器延迟计算不当**
- **位置**: `scheduled_task_service.dart` 第 285-296 行
- **代码**:
  ```dart
  final delay = nextRunMs - now;
  final safeDuration = Duration(milliseconds: delay < 1000 ? 1000 : delay);
  ```
- **问题**: 只保证最少 1 秒延迟，但如果 `nextRunAt` 本来就很接近当前时间，可能在用户看不见的情况下立即执行

#### **原因 4: 执行 Agent 指令是异步的**
- **位置**: `agent_task_executor.dart` 第 30-36 行
- **流程**:
  ```dart
  await ChatService().sendMessageToAgent(...)
  ```
- 这个调用是异步的，会立即返回消息已发送的状态

### 触发时间轴示例:

```
时间轴 (假设创建时间 09:59:45，Cron = "0 10 * * *")
────────────────────────────────────────
09:59:45  用户点击"保存"
   ↓
09:59:45  calculateNextCronRun() 从 09:59:46 开始寻找下一次 10:00
   ↓
10:00:00  找到匹配时间，nextRunAt = 10:00:00 (15秒后)
   ↓
09:59:45  activateScheduledTask() 立即调用
   ↓
09:59:45  _scheduleCronTask() 计算 delay = 15000ms
   ↓
09:59:45  Timer(15秒) 注册
   ↓
10:00:00  定时器触发！
   ↓
10:00:00  _executeTask() 执行
   ↓
10:00:00  Agent 收到指令！
────────────────────────────────────────
```

如果用户在 09:59:50 点击"保存"，delay 只有 10 秒：

```
09:59:50  点击保存
   ↓
10:00:00  定时器触发（用户还在表单页面）
   ↓
用户看起来就像"立即执行"了！
```

---

## 🔧 **Cron 表达式的生成逻辑**

### 表达式格式
标准 5 字段 Cron 格式: `minute hour day month dayOfWeek`

### 生成方法 (scheduled_task_form_screen.dart 第 280-299 行)

```dart
String _buildCronExpression() {
  final m = _cronMinute.toString().padLeft(2, '0');
  final h = _cronHour.toString();
  
  switch (_cronFrequency) {
    case _CronFrequency.daily:
      return '$m $h * * *';  // 例: "00 09 * * *"
    
    case _CronFrequency.weekly:
      final days = (_cronWeekdays.toList()..sort()).map((d) => d.toString()).join(',');
      return '$m $h * * $days';  // 例: "00 09 * * 1,2,3,4,5" (周一到周五)
    
    case _CronFrequency.monthly:
      final days = (_cronMonthdays.toList()..sort()).map((d) => d.toString()).join(',');
      return '$m $h $days * *';  // 例: "00 09 1 * *" (每月1号)
    
    case _CronFrequency.custom:
      return _cronCustomController.text.trim();  // 用户自定义
  }
}
```

### 表达式验证 (cron_parser.dart 第 10-19 行)

```dart
static bool isValidCron(String cron) {
  final parts = cron.trim().split(RegExp(r'\s+'));
  if (parts.length != 5) return false;  // 必须是 5 个字段
  
  for (final part in parts) {
    if (!_isValidCronPart(part)) return false;
  }
  return true;
}
```

### 支持的模式
- `*` - 任意值
- `0` - 具体数字
- `0,10,20` - 列表
- `0-30` - 范围
- `*/5` - 步长 (每 5 个单位)
- `0-30/5` - 范围+步长

---

## 📊 **任务状态流转**

```
pending (创建后)
  ↓
  ├→ [activateScheduledTask] → active
  │                              ↓
  │                           [pauseScheduledTask] → paused
  │                              ↓
  │                           [activateScheduledTask] → active
  │                              ↓
  │                           [执行多次]
  │
  └→ [删除] → 从系统中移除

once 类型任务:
  active → [执行一次] → completed (自动转换)

其他类型任务:
  active → [执行] → 保持 active (nextRunAt 更新)
           ↓
           [pauseScheduledTask] → paused
           ↓
           [activateScheduledTask] → active
```

---

## 💾 **数据库操作**

### 表结构 (local_database_service.dart 第 1405-1495 行)

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | TEXT | UUID v4 |
| `agent_id` | TEXT | Agent 任务必需 |
| `channel_id` | TEXT | Group 任务必需 |
| `task_type` | TEXT | 'interval', 'cron', 'once' |
| `description` | TEXT | 任务描述 |
| `status` | TEXT | 'pending', 'active', 'paused', 'completed', 'failed' |
| `instruction` | TEXT | 执行指令/提示词 |
| `schedule_pattern` | TEXT | Cron / ISO 8601 / 时间戳 |
| `next_run_at` | INTEGER | 下次运行时间 (ms) |
| `last_run_at` | INTEGER | 最后运行时间 (ms) |
| `execution_count` | INTEGER | 成功执行次数 |
| `failure_count` | INTEGER | 失败次数 |
| `last_error` | TEXT | 最后错误信息 |

### CRUD 操作
- **Create**: `createScheduledTask(task)` (第 1408-1415 行)
- **Read**: `getScheduledTaskById(id)` / `listScheduledTasks()` (第 1418-1459 行)
- **Update**: `updateScheduledTask(task)` (第 1477-1485 行)
- **Delete**: `deleteScheduledTask(id)` (第 1488-1495 行)

---

## 🎯 **关键代码位置速查表**

| 功能 | 文件 | 行号 | 方法 |
|------|------|------|------|
| **应用启动初始化** | main.dart | 118 | `main()` |
| **启动调度器** | scheduled_task_service.dart | 56-68 | `startScheduler()` |
| **创建新任务** | scheduled_task_form_screen.dart | 346-440 | `_saveTask()` |
| **立即执行** | scheduled_task_form_screen.dart | 401 | `activateScheduledTask()` |
| **立即执行按钮** | scheduled_tasks_management_screen.dart | 235-237 | `_executeTaskNow()` |
| **任务执行逻辑** | scheduled_task_service.dart | 382-430 | `_executeTask()` |
| **Cron 调度** | scheduled_task_service.dart | 284-334 | `_scheduleCronTask()` |
| **Interval 调度** | scheduled_task_service.dart | 247-282 | `_scheduleIntervalTask()` |
| **Once 调度** | scheduled_task_service.dart | 336-380 | `_scheduleOnceTask()` |
| **Cron 计算** | cron_parser.dart | 60-93 | `calculateNextCronRun()` |
| **Cron 验证** | cron_parser.dart | 10-19 | `isValidCron()` |
| **App 生命周期** | app_lifecycle_service.dart | 50-67 | `didChangeAppLifecycleState()` |
| **暂停恢复** | app_lifecycle_service.dart | 57, 65 | 暂停/恢复调度器 |

---

## 🚀 **总结**

### 三层架构
1. **Model 层**: `ScheduledTask` 数据模型
2. **Service 层**: `ScheduledTaskService` 核心调度器 + `CronParser` 工具库
3. **UI 层**: 表单屏幕 + 管理屏幕

### 三种调度方式
- **Cron**: 标准 5 字段表达式，使用递归 Timer 重新调度
- **Interval**: ISO 8601 duration，使用 `Timer.periodic`
- **Once**: 一次性任务，单个 Timer，执行后自动清理

### 立即执行的原因
1. Cron 计算可能导致 nextRunAt 非常接近当前时间
2. activateScheduledTask 立即注册定时器
3. 定时器启动后的前几秒就会触发执行
4. 用户感觉就像"立即执行"


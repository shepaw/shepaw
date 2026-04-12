# 定时任务管理系统 - 快速参考指南

## 文件结构一览

```
lib/task/
├── models/
│   └── scheduled_task.dart          ← 数据模型 (207行)
├── screens/
│   └── scheduled_tasks_management_screen.dart    ← UI界面 (724行)
├── helpers/
│   └── cron_parser.dart             ← 时间规则引擎 (305行)
└── services/
    ├── scheduled_task_service.dart  ← 核心服务 (464行)
    ├── task_executor.dart           ← 执行器接口 (10行)
    ├── agent_task_executor.dart     ← Agent执行器 (39行)
    └── group_task_executor.dart     ← 群组执行器 (29行)
```

---

## 核心数据模型快速查询

### ScheduledTask 字段

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `id` | String | UUID v4 | `"550e8400-e29b-41d4-a716-446655440000"` |
| `taskType` | String | 'interval'\|'cron'\|'once' | `'cron'` |
| `status` | String | 'pending'\|'active'\|'paused'\|'completed'\|'failed' | `'active'` |
| `schedulePattern` | String | Cron 或 ISO 8601 | `'0 9 * * *'` 或 `'PT5M'` |
| `description` | String | 任务描述 | `'Daily health check'` |
| `instruction` | String | 执行指令 | `'Check system resources'` |
| `executionTarget` | String | 'agent'\|'group' | `'agent'` |
| `agentId` | String? | Agent任务必需 | `'agent-123'` |
| `channelId` | String? | 群组任务必需 或 可选DM | `'channel-456'` |
| `agentIds` | List<String> | 群组任务的Agent列表 | `['agent-1', 'agent-2']` |
| `mentionedAgentIds` | List<String> | 要@提及的Agent | `['agent-1']` |
| `executionCount` | int | 成功执行次数 | `42` |
| `failureCount` | int | 失败次数 | `2` |
| `lastRunAt` | int? | 上次执行时间戳(ms) | `1712000000000` |
| `nextRunAt` | int | 下次执行时间戳(ms) | `1712086400000` |
| `lastError` | String? | 最后错误信息 | `'Connection timeout'` |

---

## 常用Cron表达式

```
# 格式: minute hour day month dayOfWeek (0-59) (0-23) (1-31) (1-12) (0-6)

0 9 * * *          # 每天 9:00
0 0 * * *          # 每天 00:00 (午夜)
0 */2 * * *         # 每2小时
0 9 * * 1-5         # 工作日 9:00
0 9 * * 0,6         # 周末 9:00
0 9 1 * *           # 每月1号 9:00
*/15 * * * *        # 每15分钟
0 */4 * * *         # 每4小时
30 2 * * *          # 每天 2:30 AM
0 10,14,18 * * *    # 10:00, 14:00, 18:00
```

## 常用ISO 8601 Duration

```
PT5M                # 5分钟
PT30S               # 30秒
PT1H                # 1小时
PT1H30M             # 1小时30分钟
P1D                 # 1天
P1DT2H30M           # 1天2小时30分钟
PT0.5S              # 0.5秒
```

---

## API 使用示例

### 创建任务

```dart
final taskService = ScheduledTaskService();

// Agent任务
final task = await taskService.createScheduledTask(
  agentId: 'agent-123',
  instruction: 'Check system health',
  schedulePattern: '0 9 * * *',  // 每天9:00
  description: 'Daily health check',
);

// 群组任务
final groupTask = await taskService.createScheduledTask(
  channelId: 'channel-456',
  agentIds: ['agent-1', 'agent-2'],
  mentionedAgentIds: ['agent-1'],
  instruction: 'Team standup',
  schedulePattern: '0 9 * * 1-5',  // 工作日9:00
  executionTarget: ScheduledTask.targetGroup,
);
```

### 激活/暂停任务

```dart
// 激活任务
await taskService.activateScheduledTask(task.id);

// 暂停任务
await taskService.pauseScheduledTask(task.id);

// 立即执行
await taskService.executeTaskNow(task.id);
```

### 查询任务

```dart
// 获取Agent的所有任务
final tasks = await taskService.listTasksForAgent('agent-123');

// 获取所有Active任务
final activeTasks = await taskService.listActiveTasks();

// 获取单个任务
final task = await taskService.getTask(taskId);
```

### 更新任务

```dart
final updated = task.copyWith(
  description: 'Updated description',
  schedulePattern: '0 10 * * *',  // 改为10:00
  status: ScheduledTask.statusActive,
);
await taskService.updateScheduledTask(updated);
```

### 删除任务

```dart
await taskService.deleteScheduledTask(task.id);
```

---

## CronParser 工具类

### 验证和解析

```dart
// 验证Cron表达式
bool isValid = CronParser.isValidCron('0 9 * * *');

// 解析ISO 8601 Duration
Duration? duration = CronParser.parseIsoDuration('PT5M');
// duration = Duration(minutes: 5)
```

### 计算下次运行时间

```dart
// Cron表达式
int nextRunMs = CronParser.calculateNextCronRun('0 9 * * *');

// Interval
Duration interval = Duration(minutes: 5);
int nextRunMs = CronParser.calculateNextIntervalRun(interval);
```

### 获取人类可读描述

```dart
// Cron描述
String desc = CronParser.describeCron('0 9 * * *');
// desc = 'Daily at 09:00'

// Duration描述
String desc = CronParser.describeDuration('PT1H30M');
// desc = '1 hour and 30 minutes'
```

---

## 数据库查询

### SQL 查询示例

```sql
-- 获取所有Active任务
SELECT * FROM scheduled_tasks WHERE status = 'active';

-- 按Agent筛选
SELECT * FROM scheduled_tasks WHERE agent_id = 'agent-123';

-- 获取即将运行的任务
SELECT * FROM scheduled_tasks 
WHERE next_run_at < datetime('now', '+1 hour') 
  AND status = 'active';

-- 获取失败的任务
SELECT * FROM scheduled_tasks WHERE status = 'failed';
```

### Dart ORM 查询

```dart
final db = LocalDatabaseService();

// 创建任务
await db.createScheduledTask(task);

// 获取任务
final task = await db.getScheduledTaskById(taskId);

// 列出任务
final tasks = await db.listScheduledTasks(
  agentId: 'agent-123',
  status: ScheduledTask.statusActive,
);

// 更新任务
await db.updateScheduledTask(updatedTask);

// 删除任务
await db.deleteScheduledTask(taskId);
```

---

## UI 组件位置

### 界面元素

| 组件 | 类 | 行号 | 描述 |
|------|-----|------|------|
| 任务列表 | ScheduledTasksManagementScreen | 107-141 | ListView显示所有任务 |
| 任务卡片 | _buildTaskCard | 153-247 | 单个任务的卡片展示 |
| 创建/编辑弹窗 | _TaskFormDialog | 369-723 | 任务表单对话框 |
| Agent选择 | _TaskFormDialogState | 481-508 | Agent选择下拉菜单 |
| 群组选择 | _TaskFormDialogState | 510-531 | 群组选择下拉菜单 |
| 状态徽章 | _buildStatusBadge | 250-258 | 状态显示标签 |

### 关键行号参考

```dart
// ScheduledTasksManagementScreen
44-54   Load tasks from database
107-141 Build task list
153-247 Build individual task card
260-273 Toggle task status (active/paused)
275-285 Execute task now
287-313 Confirm and delete task
315-324 Show task form dialog

// _TaskFormDialog
380-430 Initialize form state
433-440 Get channel members
443-645 Build form UI
456-475 Execution target selector
479-508 Agent mode fields
509-600 Group mode fields
604-630 Common fields (description, instruction, pattern)
647-722 Save task logic with validation
```

---

## 关键状态转移图

```
                ┌─→ paused ←─┐
                │             │
pending ──→ active ──→ [execute]
                             │
            ┌────────────────┼────────────────┐
            ▼                ▼                ▼
        completed         failed          active
                                           (next run)
```

---

## 常见操作检查清单

### 创建任务前

- [ ] 确定是Agent还是Group任务
- [ ] 验证Agent/Channel存在
- [ ] 设置正确的schedulePattern
- [ ] 编写清晰的instruction
- [ ] 设置有意义的description

### 激活任务前

- [ ] 确保任务已创建 (status='pending')
- [ ] 验证schedulePattern有效
- [ ] 检查执行器能否访问目标(Agent/Channel)

### 编辑任务时

- [ ] 使用copyWith()保持不变性
- [ ] 验证新的schedulePattern
- [ ] 如果改变目标，确保新目标有效

### 删除任务前

- [ ] 确认任务不再需要
- [ ] 已保存任何关键执行历史
- [ ] 通知相关用户

---

## 调试技巧

### 查看定时器状态

```dart
// 检查是否有活跃的定时器
print(ScheduledTaskService()._timers);

// 检查服务是否运行
print(ScheduledTaskService().isRunning);
```

### 验证Cron表达式

```dart
// 在控制台测试
final desc = CronParser.describeCron('0 9 * * *');
print(desc);  // 应输出: Daily at 09:00

// 验证格式
final valid = CronParser.isValidCron('0 9 * * *');
print(valid);  // 应输出: true
```

### 测试任务执行

```dart
// 立即执行测试
await taskService.executeTaskNow(taskId);

// 检查更新
final updated = await taskService.getTask(taskId);
print('Last run: ${updated?.lastRunAt}');
print('Execution count: ${updated?.executionCount}');
```

---

## 扩展点

### 添加新的执行器

```dart
class CustomTaskExecutor implements TaskExecutor {
  @override
  Future<void> execute(ScheduledTask task) async {
    // 自定义执行逻辑
  }
}

// 在 ScheduledTaskService._executeTask() 中添加
// final executor = _getExecutor(task.executionTarget);
```

### 自定义时间规则

```dart
// 继承 CronParser 或添加方法
static String describeCustomPattern(String pattern) {
  // 实现自定义描述逻辑
}
```

### 集成通知系统

```dart
// 在 _executeTask() 成功或失败时
await notificationService.notify(
  title: 'Task ${task.description}',
  body: 'Execution count: ${task.executionCount}',
);
```

---

## 性能优化建议

1. **分页加载** - listScheduledTasks() 添加分页参数
2. **缓存Agent信息** - 减少RemoteAgentService查询
3. **批量更新** - 使用事务更新多个任务
4. **索引优化** - 已有的索引需要定期检查
5. **定时器数量** - 监控活跃任务数量，避免过多定时器

---


# 定时任务管理系统 - 完整指南

## 📚 文档导航

本仓库包含定时任务管理系统的完整文档，请按以下顺序阅读：

1. **SCHEDULED_TASKS_EXPLORATION.md** ⭐ (推荐首先阅读)
   - 系统架构概述
   - 所有相关文件详细列表
   - 数据模型全字段说明
   - 完整的架构流程图

2. **SCHEDULED_TASKS_QUICK_REFERENCE.md** 
   - 快速API参考
   - Cron表达式示例
   - ISO 8601 Duration示例
   - 常用数据库查询
   - 调试技巧

3. **SCHEDULED_TASKS_CODE_SNIPPETS.md** 
   - 完整的代码片段
   - 复制粘贴即可使用
   - 每个模块的完整实现示例

---

## 🎯 系统概览

### 核心功能

定时任务管理系统支持两种执行目标：

#### 1️⃣ **单Agent任务** (Agent Target)
```
[用户] → [表单] → [数据库] → [定时器] → [Agent执行器] → [单个Agent]
```

- 将指令发送给单个Agent
- 可选通过指定channelId在群组中执行
- 默认在Agent的DM中执行

#### 2️⃣ **群组任务** (Group Target)  
```
[用户] → [表单] → [数据库] → [定时器] → [群组执行器] → [多个Agents]
```

- 将指令发送到指定的群组频道
- 可以选择多个Agent参与
- 支持@提及特定的Agent

### 支持的调度类型

| 类型 | 格式 | 示例 | 用途 |
|------|------|------|------|
| **Cron** | Unix cron表达式 | `0 9 * * *` | 定期重复执行 |
| **Interval** | ISO 8601 Duration | `PT5M` | 固定时间间隔执行 |
| **Once** | 时间戳 | `1712000000000` | 一次性执行 |

---

## 📁 项目结构

```
lib/task/
├── models/
│   └── scheduled_task.dart                    # 数据模型 (207行)
│
├── screens/
│   └── scheduled_tasks_management_screen.dart # 管理界面 (724行)
│
├── helpers/
│   └── cron_parser.dart                       # 时间规则引擎 (305行)
│
└── services/
    ├── scheduled_task_service.dart            # 核心调度服务 (464行)
    ├── task_executor.dart                     # 执行器接口 (10行)
    ├── agent_task_executor.dart               # Agent执行器 (39行)
    └── group_task_executor.dart               # 群组执行器 (29行)

lib/services/
└── local_database_service.dart                # 数据库层 (SQLite)

lib/screens/
└── desktop_home_screen.dart                   # 路由配置

lib/l10n/
├── app_zh.arb                                 # 中文本地化
└── app_en.arb                                 # 英文本地化
```

**总代码行数：** ~1,800行

---

## 🚀 快速开始

### 在应用启动时初始化

```dart
// main.dart 或 app_lifecycle_service.dart
Future<void> initializeScheduledTasks() async {
  final taskService = ScheduledTaskService();
  await taskService.startScheduler();
  
  // 生命周期事件
  // 前台: resumeScheduler()
  // 后台: pauseScheduler()
}
```

### 创建简单的每日任务

```dart
final taskService = ScheduledTaskService();

final task = await taskService.createScheduledTask(
  agentId: 'agent-123',
  instruction: 'Check system health and report',
  schedulePattern: '0 9 * * *',  // 每天9:00
  description: 'Daily health check',
);

// 激活任务
await taskService.activateScheduledTask(task.id);
```

### 创建群组任务

```dart
final task = await taskService.createScheduledTask(
  channelId: 'team-channel-123',
  agentIds: ['agent-1', 'agent-2', 'agent-3'],
  mentionedAgentIds: ['agent-1'],  // 只@提及agent-1
  instruction: 'Team daily standup',
  schedulePattern: '0 9 * * 1-5',  // 工作日9:00
  executionTarget: ScheduledTask.targetGroup,
);

await taskService.activateScheduledTask(task.id);
```

---

## 📊 数据流

### 完整的请求-响应流程

```
┌─────────────────────────────────────────────────────────┐
│ 1. 用户在UI中创建任务                                    │
│    - 填写表单 (目标、指令、时间表)                       │
│    - 点击保存                                            │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│ 2. 创建任务 (ScheduledTaskService.createScheduledTask)  │
│    - 验证输入                                            │
│    - 生成UUID                                            │
│    - 计算nextRunAt                                      │
│    - 状态设为 'pending'                                  │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│ 3. 保存到数据库 (LocalDatabaseService.createScheduledTask) │
│    - SQL INSERT 到 scheduled_tasks 表                    │
└──────────────────┬──────────────────────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────────────────────┐
│ 4. 激活任务 (ScheduledTaskService.activateScheduledTask) │
│    - 状态更新: pending → active                         │
│    - 创建定时器                                          │
└──────────────────┬──────────────────────────────────────┘
                   │
         ┌─────────┴──────────┐
         │ 根据schedulePattern
         │ 选择调度策略
         │
    ┌────▼─────┐  ┌────▼────┐  ┌────▼─────┐
    │Cron      │  │Interval │  │Once      │
    │递归调度  │  │周期调度  │  │单次执行  │
    └────┬─────┘  └────┬────┘  └────┬─────┘
         │            │             │
         └────────┬───┴─────────────┘
                  │
                  ▼
         ┌──────────────────┐
         │ 定时器触发或
         │ 用户手动触发
         │ (executeTaskNow)
         └────────┬─────────┘
                  │
                  ▼
    ┌─────────────────────────────┐
    │ 执行任务 (_executeTask)      │
    │ - 选择执行器 (Agent/Group)  │
    │ - 调用 executor.execute()   │
    │ - 发送消息给目标            │
    └────────────┬────────────────┘
                 │
         ┌───────┴───────┐
         │               │
    ┌────▼─────┐    ┌────▼─────┐
    │ 成功      │    │ 失败      │
    │           │    │           │
    │executionCount│ │failureCount│
    │+1         │    │+1         │
    │lastError  │    │lastError  │
    │=null      │    │=错误信息  │
    └────┬─────┘    └────┬─────┘
         │               │
         └───────┬───────┘
                 │
                 ▼
         ┌──────────────────────┐
         │ 更新数据库            │
         │ - lastRunAt          │
         │ - nextRunAt (重新计算)│
         │ - 计数和错误信息      │
         └──────────┬───────────┘
                    │
            ┌───────┴────────┐
            │ 任务类型       │
            │ 决定下一步     │
            │
        ┌───▼───┐ ┌───▼────┐ ┌───▼────┐
        │Cron   │ │Interval│ │Once    │
        │重新   │ │继续    │ │删除    │
        │调度   │ │运行    │ │定时器  │
        └───────┘ └────────┘ └────────┘
```

---

## 🔧 关键API参考

### ScheduledTaskService (单例)

```dart
// 生命周期
await ScheduledTaskService().startScheduler();    // 应用启动
await ScheduledTaskService().pauseScheduler();    // 进入后台
await ScheduledTaskService().resumeScheduler();   // 返回前台

// 创建和激活
final task = await ScheduledTaskService().createScheduledTask(...);
await ScheduledTaskService().activateScheduledTask(task.id);

// 管理
await ScheduledTaskService().pauseScheduledTask(taskId);
await ScheduledTaskService().executeTaskNow(taskId);
await ScheduledTaskService().updateScheduledTask(task);
await ScheduledTaskService().deleteScheduledTask(taskId);

// 查询
final tasks = await ScheduledTaskService().listTasksForAgent(agentId);
final activeTasks = await ScheduledTaskService().listActiveTasks();
final task = await ScheduledTaskService().getTask(taskId);
```

### CronParser (工具类)

```dart
// 验证和解析
CronParser.isValidCron('0 9 * * *');                     // true
CronParser.parseIsoDuration('PT5M');                     // Duration
CronParser.calculateNextCronRun('0 9 * * *');            // int (ms)
CronParser.calculateNextIntervalRun(Duration(minutes: 5)); // int (ms)

// 人类可读
CronParser.describeCron('0 9 * * *');                    // 'Daily at 09:00'
CronParser.describeDuration('PT1H30M');                  // '1 hour and 30 minutes'
```

---

## 📈 常见用例

### 1. 每小时检查一次
```dart
await taskService.createScheduledTask(
  agentId: 'monitor-agent',
  instruction: 'Check system status',
  schedulePattern: '0 * * * *',  // 每小时的0分
);
```

### 2. 每15分钟执行一次
```dart
await taskService.createScheduledTask(
  agentId: 'sync-agent',
  instruction: 'Sync data',
  schedulePattern: 'PT15M',  // ISO 8601 Duration
);
```

### 3. 工作日早9点晨会
```dart
await taskService.createScheduledTask(
  channelId: 'team-channel',
  agentIds: ['pm', 'dev-lead', 'qa-lead'],
  instruction: 'Daily standup time!',
  schedulePattern: '0 9 * * 1-5',  // 周一到周五9:00
  executionTarget: ScheduledTask.targetGroup,
);
```

### 4. 每周一报告
```dart
await taskService.createScheduledTask(
  agentId: 'report-agent',
  instruction: 'Generate weekly report',
  schedulePattern: '0 9 * * 1',  // 每周一9:00
);
```

### 5. 一次性执行
```dart
final nextMonday = DateTime.now().add(Duration(days: 7));
await taskService.createScheduledTask(
  agentId: 'agent-123',
  instruction: 'Special task',
  schedulePattern: nextMonday.toString(),  // 一次性
);
```

---

## 🐛 常见问题和解决方案

### Q: 任务为什么没有执行？
```dart
// 检查清单：
1. 确认任务状态是 'active' (不是 'pending' 或 'paused')
   final task = await taskService.getTask(taskId);
   print(task?.status);

2. 验证schedulePattern格式
   final isValid = CronParser.isValidCron('0 9 * * *');
   print(isValid);

3. 检查nextRunAt是否在过去
   final desc = CronParser.describeCron(task.schedulePattern);
   print('Next scheduled: $desc');

4. 确认目标Agent/Channel存在
   final agent = await agentService.getAgentById(task.agentId);
   print(agent != null ? 'Agent exists' : 'Agent not found');
```

### Q: 如何更改任务的时间表？
```dart
final updated = task.copyWith(
  schedulePattern: '0 10 * * *',  // 改为10:00
  updatedAt: DateTime.now().millisecondsSinceEpoch,
);
await taskService.updateScheduledTask(updated);
```

### Q: 如何查看任务的执行历史？
```dart
final task = await taskService.getTask(taskId);
print('Execution count: ${task?.executionCount}');
print('Failure count: ${task?.failureCount}');
print('Last run at: ${DateTime.fromMillisecondsSinceEpoch(task?.lastRunAt ?? 0)}');
print('Last error: ${task?.lastError}');
```

### Q: 如何实现任务重试机制？
```dart
// 在GroupTaskExecutor或AgentTaskExecutor中添加重试逻辑
Future<void> executeWithRetry(ScheduledTask task, {int retries = 3}) async {
  int attempt = 0;
  while (attempt < retries) {
    try {
      await execute(task);
      return;  // 成功
    } catch (e) {
      attempt++;
      if (attempt >= retries) rethrow;
      await Future.delayed(Duration(seconds: 2 * attempt));  // 指数退避
    }
  }
}
```

---

## 🔐 安全注意事项

1. **权限验证** - 确认用户有权创建/修改任务
2. **指令验证** - 在执行前验证instruction内容
3. **速率限制** - 避免创建过多频繁的任务
4. **数据加密** - 对敏感参数进行加密存储
5. **审计日志** - 记录所有任务的创建/修改/执行事件

---

## 📚 扩展阅读

- **Cron表达式语法** - https://crontab.guru/
- **ISO 8601 Duration** - https://en.wikipedia.org/wiki/ISO_8601#Duration
- **Flutter Timer文档** - https://api.flutter.dev/flutter/dart-async/Timer-class.html
- **SQLite优化** - https://www.sqlite.org/bestindex.html

---

## 🎓 学习路径

### 初级（理解基础）
1. 阅读 SCHEDULED_TASKS_EXPLORATION.md 的架构部分
2. 理解 ScheduledTask 数据模型
3. 查看 SCHEDULED_TASKS_QUICK_REFERENCE.md 的API示例

### 中级（开发功能）
1. 研究 scheduled_task_service.dart 的实现
2. 学习 cron_parser.dart 的规则引擎
3. 查看 scheduled_tasks_management_screen.dart 的UI实现

### 高级（优化扩展）
1. 研究 Timer 的性能特性
2. 实现自定义执行器
3. 添加队列/优先级机制
4. 集成监控和告警系统

---

## 📞 支持和反馈

如有问题或建议，请：
1. 查看相关文档
2. 检查代码注释
3. 在SCHEDULED_TASKS_CODE_SNIPPETS.md中查找类似示例
4. 运行测试和调试代码

---

**文档最后更新:** 2026-04-12
**系统版本:** v1.0
**作者:** Code Explorer

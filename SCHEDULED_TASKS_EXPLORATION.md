# 定时任务管理系统 - 代码库探索报告

## 项目概述
这是一个Flutter应用中的定时任务管理系统，支持以下功能：
- **定时任务列表管理页面** - 查看、编辑、删除定时任务
- **创建/编辑定时任务弹窗** - 支持Agent和Group两种执行目标
- **时间规则处理** - 支持Cron表达式和ISO 8601持续时间格式
- **任务执行引擎** - 自动执行定时任务

---

## 📁 相关文件列表

### 1. **核心模型** (Models)

#### `lib/task/models/scheduled_task.dart` (207行)
定时任务数据模型，包含以下主要字段：

**任务执行配置：**
```dart
- id: String                          // UUID v4
- agentId: String?                    // 单个Agent任务：必需；群组任务：null
- channelId: String?                  // 可选的群组通道覆盖或DM频道
- executionTarget: String             // 'agent' 或 'group'
- agentIds: List<String>              // 群组任务：所有参与Agent
- mentionedAgentIds: List<String>     // 群组任务：要@提及的Agent子集
```

**任务内容：**
```dart
- taskType: String                    // 'interval', 'cron', 'once'
- description: String                 // 任务描述
- instruction: String                 // 执行指令/提示词
- parameters: Map<String, dynamic>?   // 任务特定配置
- schedulePattern: String             // Cron表达式 或 ISO 8601 Duration
```

**执行状态：**
```dart
- status: String                      // 'pending', 'active', 'paused', 'completed', 'failed'
- executionCount: int                 // 成功执行次数
- failureCount: int                   // 失败执行次数
- lastRunAt: int?                     // 上次执行时间戳(ms)
- nextRunAt: int                      // 下次执行时间戳(ms)
- lastError: String?                  // 最后一次失败的错误信息
```

**审计信息：**
```dart
- createdAt: int                      // 创建时间戳(ms)
- updatedAt: int                      // 更新时间戳(ms)
- createdBy: String                   // 创建用户ID
```

**工厂方法：**
- `fromJson()` - 从数据库JSON反序列化
- `toJson()` - 转换为数据库JSON格式
- `copyWith()` - 不可变更新

---

### 2. **界面层** (Screens & Widgets)

#### `lib/task/screens/scheduled_tasks_management_screen.dart` (724行)

**主要组件：**

**a) ScheduledTasksManagementScreen (状态容器)**
- 加载并显示所有定时任务
- 支持按Agent筛选
- FloatingActionButton 创建新任务

**b) _buildTaskCard() - 任务卡片显示**
```dart
显示内容：
- 任务描述 (标题)
- 执行目标 (Agent名称 或 "Group task · N agents")
- 状态徽章 (Active/Paused/Completed/Failed)
- 时间表描述 (使用CronParser)
- 执行/失败计数
- 最后错误信息 (如有)

操作按钮：
- 启用/暂停任务
- 立即执行
- 编辑
- 删除
```

**c) _TaskFormDialog - 创建/编辑弹窗**

*执行目标选择：*
```dart
SegmentedButton: 'Agent' | 'Group'
- 切换时重置目标特定字段
```

**Agent目标模式：**
```dart
1. Agent选择 (必需) - DropdownButtonFormField
2. 可选频道覆盖 - 用于DM/群组消息
```

**Group目标模式：**
```dart
1. 群组频道选择 (必需) - DropdownButtonFormField
   - 仅显示type='group'的频道
2. Agent多选 (必需) - FilterChips
   - 来自频道成员
3. @提及Agent子集 (可选) - FilterChips
   - 从已选Agent中选择
```

**任务配置字段：**
- `description` - TextField
- `instruction` - TextField (3行)
- `schedulePattern` - TextField (Cron/ISO 8601)

**验证逻辑：**
```dart
Agent模式：
- agentId 必需
- instruction 必需
- schedulePattern 必需

Group模式：
- channelId 必需
- agentIds 不能为空
- instruction 必需
- schedulePattern 必需
```

---

### 3. **时间规则处理** (Helpers)

#### `lib/task/helpers/cron_parser.dart` (305行)

**核心功能：**

**a) Cron验证和解析**
```dart
static bool isValidCron(String cron)
// 验证格式：minute hour day month dayOfWeek (5部分)
// 示例: "0 9 * * *" ✓
```

**b) ISO 8601 Duration解析**
```dart
static Duration? parseIsoDuration(String durationStr)
// 示例：
// "PT5M" → Duration(minutes: 5)
// "PT1H30M" → Duration(hours: 1, minutes: 30)
// "P1D" → Duration(days: 1)
// "PT30S" → Duration(seconds: 30)

// 正则表达式: ^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$
```

**c) 下次运行时间计算**
```dart
static int calculateNextCronRun(String cronExpression, {int? fromTime})
// 返回毫秒时间戳
// 搜索范围：当前 → 未来4年
// 搜索步长：1分钟

static int calculateNextIntervalRun(Duration interval, {int? fromTime})
// 返回 fromTime + interval
```

**d) 人类可读的描述**
```dart
static String describeCron(String cronExpression)
// 示例：
// "0 9 * * *" → "Daily at 09:00"
// "0 */2 * * *" → "Every 2 hours"
// "0 9 * * 1-5" → "Weekdays at 09:00"

static String describeDuration(String durationStr)
// 示例：
// "PT1H30M" → "1 hour and 30 minutes"
```

**e) Cron匹配规则**
```dart
static bool _matchesCronPart(int value, String pattern)
// 支持的模式：
// - "*" 匹配任何值
// - "5" 精确匹配5
// - "5,10,15" 列表
// - "5-10" 范围
// - "*/5" 步长 (0, 5, 10, 15, ...)
// - "5-20/5" 范围+步长

static bool _matchesCronDayOfWeek(int dateTimeWeekday, String pattern)
// DateTime: 1=Monday, 7=Sunday
// Cron: 0=Sunday, 1=Monday, ..., 6=Saturday
// 支持环绕范围: "5-1" = Fri,Sat,Sun,Mon
```

---

### 4. **业务逻辑** (Services)

#### `lib/task/services/scheduled_task_service.dart` (464行)

**单例模式服务，管理任务调度生命周期**

**主要方法：**

**a) 生命周期管理**
```dart
Future<void> startScheduler()
// 应用启动时调用一次
// 加载所有Active状态的任务并调度

Future<void> pauseScheduler()
// 应用进入后台时调用
// 取消所有定时器，但保留任务状态

Future<void> resumeScheduler()
// 应用返回前台时调用
// 重新调度所有Active任务
```

**b) 任务操作**
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
})
// 创建处于'pending'状态的新任务
// 返回ScheduledTask对象

Future<void> activateScheduledTask(String taskId)
// 激活任务：pending → active
// 立即调度执行

Future<void> pauseScheduledTask(String taskId)
// 暂停任务：active → paused
// 取消定时器

Future<void> deleteScheduledTask(String taskId)
// 永久删除任务
// 取消定时器并从数据库删除

Future<void> executeTaskNow(String taskId)
// 立即执行任务（忽略时间表）

Future<void> updateScheduledTask(ScheduledTask task)
// 更新任务信息
```

**c) 查询方法**
```dart
Future<List<ScheduledTask>> listTasksForAgent(String agentId)
Future<List<ScheduledTask>> listActiveTasks()
Future<ScheduledTask?> getTask(String taskId)
```

**d) 内部调度逻辑**

**Interval任务调度 (ISO 8601):**
```dart
void _scheduleIntervalTask(ScheduledTask task)
// Timer.periodic(duration, ...) 
// 每个周期自动重新运行
// 示例：PT5M → 每5分钟运行一次
```

**Cron任务调度:**
```dart
void _scheduleCronTask(ScheduledTask task)
// Timer(duration, ...) 只执行一次
// 执行后计算下次运行时间
// 递归调度直到任务暂停/删除
// 示例：0 9 * * * → 每天9:00运行
```

**One-time任务调度:**
```dart
void _scheduleOnceTask(ScheduledTask task)
// Timer(duration, ...) 在nextRunAt时刻执行一次
// 执行后从定时器映射中移除
```

**e) 执行流程**
```dart
Future<void> _executeTask(ScheduledTask task)
1. 获取正确的执行器 (Agent vs Group)
2. 调用 executor.execute(task)
3. 成功时：
   - lastRunAt = 现在
   - executionCount++
   - nextRunAt = 计算下次运行
   - lastError = null
4. 失败时：
   - lastRunAt = 现在
   - failureCount++
   - lastError = 异常信息
   - nextRunAt = 计算下次运行
5. 更新数据库
```

---

#### `lib/task/services/task_executor.dart` (10行)

**抽象基类，定义执行接口**
```dart
abstract class TaskExecutor {
  Future<void> execute(ScheduledTask task);
}
```

---

#### `lib/task/services/agent_task_executor.dart` (39行)

**单Agent任务执行器**
```dart
class AgentTaskExecutor implements TaskExecutor

execute(ScheduledTask task):
1. 验证 task.agentId 不为null
2. 通过RemoteAgentService获取Agent
3. 使用ChatService发送消息到Agent：
   - channelId: task.channelId 或 null (DM)
   - content: task.instruction
   - userId: 'user'
   - userName: 'User'
```

---

#### `lib/task/services/group_task_executor.dart` (29行)

**群组任务执行器**
```dart
class GroupTaskExecutor implements TaskExecutor

execute(ScheduledTask task):
1. 验证 task.channelId 不为null
2. 验证 task.agentIds 不为空
3. 使用ChatService发送消息到群组：
   - channelId: task.channelId
   - content: task.instruction
   - agentIds: task.agentIds (接收方)
   - mentionedAgentIds: task.mentionedAgentIds (@提及)
   - userId: 'user'
   - userName: 'User'
```

---

### 5. **数据持久化** (Database)

#### `lib/services/local_database_service.dart`

**表结构：scheduled_tasks**
```sql
CREATE TABLE IF NOT EXISTS scheduled_tasks (
  id TEXT PRIMARY KEY,
  agent_id TEXT,
  channel_id TEXT,
  task_type TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL,
  instruction TEXT NOT NULL,
  parameters TEXT,
  schedule_pattern TEXT NOT NULL,
  last_run_at INTEGER,
  next_run_at INTEGER NOT NULL,
  execution_count INTEGER NOT NULL DEFAULT 0,
  failure_count INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  created_by TEXT NOT NULL,
  execution_target TEXT NOT NULL DEFAULT 'agent',
  agent_ids TEXT,                    -- JSON数组
  mentioned_agent_ids TEXT           -- JSON数组
)
```

**索引：**
```sql
idx_scheduled_tasks_status    → (status)
idx_scheduled_tasks_next_run  → (next_run_at)
idx_scheduled_tasks_agent     → (agent_id)
idx_scheduled_tasks_channel   → (channel_id)
idx_scheduled_tasks_target    → (execution_target)
```

**CRUD操作：**
```dart
Future<void> createScheduledTask(ScheduledTask task)
Future<ScheduledTask?> getScheduledTaskById(String id)
Future<List<ScheduledTask>> listScheduledTasks({
  String? agentId,
  String? status,
  String? channelId,
})
Future<void> updateScheduledTask(ScheduledTask task)
Future<void> deleteScheduledTask(String id)
```

---

### 6. **路由配置** (Navigation)

#### `lib/screens/desktop_home_screen.dart`

**路由枚举：**
```dart
enum _RightPanelView {
  empty,
  chat,
  settings,
  addAgent,
  createGroup,
  contacts,
  search,
  traces,
  modelManagement,
  skillManagement,
  toolConfigManagement,
  scheduledTaskManagement,  // ← 定时任务
}
```

**侧边栏配置 (第389-394行)：**
```dart
_SidebarItemDef(
  icon: Icons.schedule,
  tooltip: l10n.scheduledTasks_title,
  colorBuilder: (_) => _rightPanel == _RightPanelView.scheduledTaskManagement
      ? activeColor
      : iconColor,
  onTap: () => _showPanel(_RightPanelView.scheduledTaskManagement),
)
```

**面板路由 (第304-305行)：**
```dart
case _RightPanelView.scheduledTaskManagement:
  return const ScheduledTasksManagementScreen();
```

---

### 7. **国际化** (Localization)

#### `lib/l10n/app_zh.arb` 和 `app_en.arb`

**关键词汇：**
```json
// 页面标题
"scheduledTasks_title": "定时任务"
"scheduledTasks_description": "管理自动执行的定时任务"

// 列表页面
"scheduledTasks_noTasks": "还没有定时任务"
"scheduledTasks_noTasksHint": "创建一个新任务来开始"
"scheduledTasks_executionCount": "执行: {count}"
"scheduledTasks_failureCount": "失败: {count}"
"scheduledTasks_lastError": "最后错误: {error}"

// 操作
"scheduledTasks_createTask": "创建任务"
"scheduledTasks_editTask": "编辑任务"
"scheduledTasks_deleteTask": "删除任务"
"scheduledTasks_activateTask": "启用"
"scheduledTasks_pauseTask": "暂停"
"scheduledTasks_executeNow": "立即执行"
"scheduledTasks_confirmDelete": "确认删除"
"scheduledTasks_confirmDeleteMsg": "此操作无法撤销"
"scheduledTasks_deleteSuccess": "任务已删除"
"scheduledTasks_createSuccess": "任务已创建"
"scheduledTasks_updateSuccess": "任务已更新"

// 状态
"scheduledTasks_status_pending": "待处理"
"scheduledTasks_status_active": "活动"
"scheduledTasks_status_paused": "暂停"
"scheduledTasks_status_completed": "已完成"
"scheduledTasks_status_failed": "已失败"

// 表单字段
"scheduledTasks_form_description": "描述"
"scheduledTasks_form_descriptionHint": "这个任务的用途是什么？"
"scheduledTasks_form_instruction": "指令"
"scheduledTasks_form_instructionHint": "输入任务指令或提示"
"scheduledTasks_form_schedulePattern": "时间安排"
"scheduledTasks_form_schedulePatternHint": "Cron: 0 9 * * * 或 Duration: PT5M"
"scheduledTasks_form_selectAgent": "选择智能体"
"scheduledTasks_form_selectGroupChannel": "选择群组频道"
"scheduledTasks_form_selectGroupAgents": "选择群组内的智能体"
"scheduledTasks_form_selectMentions": "选择要@提及的智能体"

// 目标
"scheduledTasks_targetAgent": "单个智能体"
"scheduledTasks_targetGroup": "群组"

// 验证错误
"scheduledTasks_missingAgent": "请选择一个智能体"
"scheduledTasks_missingChannel": "请选择一个群组频道"
"scheduledTasks_missingGroupAgents": "请选择至少一个智能体"
"scheduledTasks_missingInstruction": "请输入指令"
```

---

## 📊 架构流程图

```
┌─────────────────────────────────────────────────────────────────┐
│                    DesktopHomeScreen                            │
│              (路由 → ScheduledTasksManagementScreen)             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
         ┌─────────────────┴──────────────────┐
         │                                    │
    ┌────▼──────────────────┐     ┌──────────▼─────────┐
    │  Task List View       │     │ Task Form Dialog  │
    │  (_buildTaskCard)     │     │ (_TaskFormDialog) │
    └────────┬──────────────┘     └──────────┬────────┘
             │                               │
             └───────────────┬───────────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
         ┌────▼─────────────────┐   ┌──────▼────────────────┐
         │ LocalDatabaseService │   │ ScheduledTaskService │
         │ (CRUD Operations)    │   │ (Scheduling Logic)   │
         └────┬──────────────────┘   └──────┬───────────────┘
              │                             │
         ┌────▼──────────────────┐          │
         │  scheduled_tasks      │          │
         │  (SQLite Table)       │     ┌────▼──────────────┐
         └───────────────────────┘     │ Timer Management  │
                                       │ (Interval/Cron)   │
                                       └────┬──────────────┘
                                            │
                     ┌──────────────────────┼──────────────────────┐
                     │                      │                      │
                ┌────▼────────┐      ┌─────▼──────┐      ┌────────▼────┐
                │ TaskExecutor │      │ TaskExecutor│     │ TaskExecutor│
                │ (Interface)  │      │ (Agent)    │     │ (Group)     │
                └──────────────┘      └─────┬──────┘     └────────┬────┘
                                            │                     │
                                      ┌─────▼──────────────────────▼──┐
                                      │     ChatService               │
                                      │  (Message Dispatch)           │
                                      └───────────────────────────────┘
```

---

## 🔄 任务执行生命周期

```
┌────────────────────────────────────────────────────────────────┐
│  1. 创建 (Create)                                              │
│  - 用户在表单中填写信息                                         │
│  - 调用 ScheduledTaskService.createScheduledTask()             │
│  - 任务状态: 'pending'                                          │
│  - 保存到数据库                                                 │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  2. 激活 (Activate)                                            │
│  - 用户点击"启用"按钮                                           │
│  - 调用 ScheduledTaskService.activateScheduledTask()           │
│  - 任务状态: 'pending' → 'active'                              │
│  - 根据schedulePattern类型调度:                                │
│    • typeInterval: Timer.periodic()                            │
│    • typeCron: Timer() 递归                                    │
│    • typeOnce: Timer() 单次                                    │
└────────────────────────────────────────────────────────────────┘
                          │
                          ▼
┌────────────────────────────────────────────────────────────────┐
│  3. 执行 (Execute)                                             │
│  - 定时器触发时执行                                             │
│  - 或用户点击"立即执行"按钮                                     │
│  - 调用 executor.execute(task):                                │
│    • AgentTaskExecutor: ChatService.sendMessageToAgent()       │
│    • GroupTaskExecutor: ChatService.sendMessageToGroup()       │
└────────────────────────────────────────────────────────────────┘
                          │
              ┌───────────┴───────────┐
              │                       │
         ┌────▼─────┐            ┌────▼──────┐
         │ Success  │            │ Failure   │
         │          │            │           │
         │ +exec   │            │ +fail     │
         │ +next   │            │ +error    │
         └────┬─────┘            └────┬──────┘
              │                       │
              └───────────┬───────────┘
                          │
                          ▼
         ┌────────────────────────────────┐
         │  更新数据库                     │
         │  (lastRunAt, nextRunAt, 计数)  │
         └────────────────────────────────┘
                          │
              ┌───────────┴────────────┐
              │                        │
         ┌────▼──────┐           ┌─────▼────┐
         │ 重新调度   │           │ 暂停/删除  │
         │ (Cron/Int)│           │ (状态变更) │
         └────────────┘           └──────────┘
```

---

## 🎯 关键特性总结

### 支持的调度类型
| 类型 | 格式 | 示例 | 说明 |
|------|------|------|------|
| **Cron** | 5部分Cron表达式 | `0 9 * * *` | 每天9:00执行 |
| **Interval** | ISO 8601 Duration | `PT5M` | 每5分钟执行 |
| **Once** | nextRunAt时间戳 | 1712000000000 | 一次性执行 |

### 执行目标
| 目标 | 必需字段 | 可选字段 |
|------|--------|--------|
| **Agent** | agentId | channelId |
| **Group** | channelId, agentIds | mentionedAgentIds |

### 任务状态流转
```
pending → active ⇄ paused → completed/failed
         ↓
    (error) ↓ fail_count++
    ↑______________↓
```

---

## 🔐 数据库迁移历史

**版本 v20 → v21：**
- 添加 `execution_target` 字段（默认:'agent'）
- 添加 `agent_ids` 字段（JSON数组）
- 添加 `mentioned_agent_ids` 字段（JSON数组）
- 用途：支持群组任务

---


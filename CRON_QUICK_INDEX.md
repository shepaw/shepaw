# CronCreate / 定时任务系统 - 快速索引

## 📋 相关文件路径汇总

### 核心实现 (4 个文件)
| 文件 | 行数 | 关键方法 |
|------|------|----------|
| **lib/task/helpers/cron_parser.dart** | 305 | `isValidCron()` (第10-19), `parseIsoDuration()` (第29-54), `calculateNextCronRun()` (第60-93) |
| **lib/task/models/scheduled_task.dart** | 207 | `fromJson()` (第84-109), `toJson()` (第112-133) |
| **lib/task/services/scheduled_task_service.dart** | 480 | `createScheduledTask()` (第109-152), `_scheduleCronTask()` (第284-334), `_executeTask()` (第382-430) |
| **lib/services/local_database_service.dart** | 1496 | `createScheduledTask()` (第1408), `getScheduledTaskById()` (第1418), `updateScheduledTask()` (第1477) |

### 执行器 (2 个文件)
| 文件 | 行数 | 职责 |
|------|------|------|
| **lib/task/services/agent_task_executor.dart** | 39 | 单Agent 执行 |
| **lib/task/services/group_task_executor.dart** | 29 | 群组任务执行 |

### UI 界面 (2 个文件)
| 文件 | 行数 | 职责 |
|------|------|------|
| **lib/task/screens/scheduled_task_form_screen.dart** | ~400 | 任务创建/编辑表单 |
| **lib/task/screens/scheduled_tasks_management_screen.dart** | 724 | 任务管理列表 |

### 本地化 (3 个文件)
| 文件 | 职责 |
|------|------|
| **lib/l10n/app_zh.arb** | 中文字符串 |
| **lib/l10n/app_en.arb** | 英文字符串 |
| **lib/l10n/app_localizations.dart** | L10n 生成的类 |

---

## 🔑 关键代码位置速查表

### 1️⃣ Cron 表达式验证
**文件**: `lib/task/helpers/cron_parser.dart`
- **验证方法**: `isValidCron()` (第10-19行)
- **单部分验证**: `_isValidCronPart()` (第278-303行)

### 2️⃣ Duration 解析  
**文件**: `lib/task/helpers/cron_parser.dart`
- **ISO 8601 解析**: `parseIsoDuration()` (第29-54行)
- **正则模式**: `^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$`

### 3️⃣ 下次执行时间计算
**文件**: `lib/task/helpers/cron_parser.dart`
- **Cron 计算**: `calculateNextCronRun()` (第60-93行)
- **Interval 计算**: `calculateNextIntervalRun()` (第95-100行)
- **Fallback**: 无效 cron 返回 1 小时后 (第92行)

### 4️⃣ Cron 部分匹配
**文件**: `lib/task/helpers/cron_parser.dart`
- **数值匹配**: `_matchesCronPart()` (第198-234行)
- **周几匹配**: `_matchesCronDayOfWeek()` (第240-276行)

### 5️⃣ 任务创建
**文件**: `lib/task/services/scheduled_task_service.dart`
- **创建**: `createScheduledTask()` (第109-152行)
- **任务类型检测**: `_getTaskType()` (第432-452行)
- **下次执行计算**: `_calculateNextRun()` (第454-466行)

### 6️⃣ 任务调度
**文件**: `lib/task/services/scheduled_task_service.dart`
- **Cron 调度**: `_scheduleCronTask()` (第284-334行)
- **Interval 调度**: `_scheduleIntervalTask()` (第247-282行)
- **一次性调度**: `_scheduleOnceTask()` (第336-380行)

### 7️⃣ 任务执行
**文件**: `lib/task/services/scheduled_task_service.dart`
- **执行**: `_executeTask()` (第382-430行)
- **执行器选择**: 第391-393行

### 8️⃣ 数据库操作
**文件**: `lib/services/local_database_service.dart`
- **表定义**: 第291-318行
- **创建**: `createScheduledTask()` (第1408行)
- **查询单条**: `getScheduledTaskById()` (第1418行)
- **列表查询**: `listScheduledTasks()` (第1429行)
- **更新**: `updateScheduledTask()` (第1477行)
- **删除**: `deleteScheduledTask()` (第1488行)

---

## ⚙️ Invalid 处理流程

### 场景 A: 无效的 Cron 表达式
```
createScheduledTask() 
  ↓ _calculateNextRun() 
  ↓ calculateNextCronRun() 
  ↓ 检查是否为 5 个字段
  ├─ NO → 返回 fromTime (当前时间) ❌
  ├─ YES → 寻找下次匹配
     ├─ 找到 → 返回时间戳 ✓
     └─ 未找到(4年内) → 返回 fromTime + 1小时 ⚠️
```

### 场景 B: 无效的 ISO 8601 Duration
```
_scheduleIntervalTask()
  ↓ parseIsoDuration()
  ├─ 正则不匹配 → 返回 null
  └─ 异常 → 返回 null
  ↓ duration == null?
  ├─ YES → 记录错误，return (任务不调度) ❌
  └─ NO → Timer.periodic() ✓
```

### 场景 C: 一次性任务过期
```
_scheduleOnceTask()
  ↓ 计算延迟时间
  ├─ delay < -60000ms? 
  │  ├─ YES → 标记为 completed，不执行 ⚠️
  │  └─ NO → 正常调度 ✓
```

---

## 📊 数据流向

```
UI Form
  ↓
createScheduledTask()
  ├─ _getTaskType() → 检测类型 (cron/interval/once)
  ├─ _calculateNextRun() → 计算 nextRunAt
  └─ _db.createScheduledTask() → SQLite 保存
  ↓
activateScheduledTask()
  ├─ 更新 status = 'active'
  └─ _scheduleTask() 调度
  ↓
_scheduleTask()
  ├─ taskType = 'cron' → _scheduleCronTask()
  ├─ taskType = 'interval' → _scheduleIntervalTask()
  └─ taskType = 'once' → _scheduleOnceTask()
  ↓
Timer 触发时
  ↓
_executeTask()
  ├─ executor.execute(task)
  ├─ 更新 lastRunAt, executionCount
  ├─ 计算 nextRunAt
  └─ _db.updateScheduledTask()
  ↓
重新调度 (cron 和 interval)
```

---

## 🎯 三大核心逻辑

### 1. Cron 表达式解析
**负责**: `CronParser` 类
**流程**:
1. `isValidCron()` - 检查格式是否为 5 个字段
2. 若无效，返回 false
3. `_isValidCronPart()` - 逐字段验证 (支持 *, 数字, 范围, 列表, 步长)
4. `_matchesCronPart()` - 检查特定时间是否匹配
5. `calculateNextCronRun()` - 计算下次执行时间

**Fallback**: 
- 无效格式 → 返回当前时间
- 无匹配(4年内) → 返回 1 小时后

### 2. Duration 解析  
**负责**: `CronParser.parseIsoDuration()`
**支持格式**:
- `PT5M` - 5 分钟
- `PT1H` - 1 小时
- `PT1H30M` - 1 小时 30 分钟
- `P1D` - 1 天
- `P1DT2H30M` - 1 天 2 小时 30 分钟

**Fallback**: 无效格式 → 返回 null

### 3. 任务调度与执行
**负责**: `ScheduledTaskService` 类
**流程**:
1. 任务创建时计算 `nextRunAt`
2. 激活任务时启动相应类型的定时器
3. 定时器触发时重新检查任务状态
4. 执行任务并更新计数
5. 计算下一次执行时间
6. 重新调度 (cron/interval) 或标记完成 (once)

**Fallback**:
- 一次性任务过期 60+ 秒 → 标记完成，不执行
- Invalid Duration → 记录错误，不调度

---

## 🧪 测试焦点

### 单元测试
- [ ] `CronParser.isValidCron()` 各种格式
- [ ] `CronParser._matchesCronPart()` 各种模式
- [ ] `CronParser._matchesCronDayOfWeek()` 周几转换
- [ ] `CronParser.parseIsoDuration()` ISO 8601 格式
- [ ] `CronParser.calculateNextCronRun()` 下次执行时间

### 集成测试
- [ ] 创建 cron 任务，检查 `nextRunAt`
- [ ] 创建 interval 任务，检查执行频率
- [ ] 创建 once 任务，检查一次性执行
- [ ] 无效输入的 fallback 行为
- [ ] 任务执行后的重新调度

---

## 📚 相关文档

- `SCHEDULED_TASKS_README.md` - 系统完整指南
- `SCHEDULED_TASKS_EXPLORATION.md` - 代码库探索
- `SCHEDULED_TASKS_QUICK_REFERENCE.md` - 快速参考
- `SCHEDULED_TASKS_CODE_SNIPPETS.md` - 代码片段
- `CRON_IMPLEMENTATION_ANALYSIS.md` - **本次新增** 完整分析


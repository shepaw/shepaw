# 对话模式控制权归属：决策记录（群聊 + 单聊）

> 状态：§5.1 已拍板（Plan Mode 保留并扩展到单聊），其余待确认
> 日期：2026-09-11
> 更新 1：2026-09-11 补入单聊计划模式调研结论（§2.5、§5.1）
> 更新 2：2026-09-11 文档债已清（§2.4、§5.1.3）

## 1. 问题

群聊／单聊的「模式」到底由用户显式开关控制，还是交给 Admin Agent 自主决策？

当前这不是二选一——代码里三层控制已经并存，但混在一起没有分层，导致：
- 新增一个编排策略时，无从判断该加 UI 开关还是写死；
- 用户面对一堆看不懂的旋钮（"阶段门闸"到底是什么？）；
- 文档承诺的模式和代码实现已经对不上。

## 2. 现状盘点

### 2.1 用户开关（4 个，分布在两处）

| 开关 | 模型字段 | 聊天面板 | 群详情页 |
|---|---|---|---|
| 提及模式 `adminOnly`/`allMembers` | `channel.dart:123` | `chat_screen.dart:2924` | `group_detail_screen.dart:763` |
| 最大编排轮次 | `channel.dart:121` | `chat_screen.dart:2961` | `group_detail_screen.dart:797` |
| Flow 模式 | `channel.dart:125` | `chat_screen.dart:2970` | `group_detail_screen.dart:806` |
| 阶段门闸 | `channel.dart:127` | `chat_screen.dart:2978` | `group_detail_screen.dart:814` |

提及模式与最大轮次在**建群时**还要再选一次（`create_group_screen.dart:529`、`:507`），
即同一组配置散落在三个入口。

### 2.2 Admin 自主决策（已有先例）

- 阶段门闸：admin 输出 `[GATE_DECISION: continue|abort|reassign:名字]`，`group_stage_gate.dart:36` 解析。
  解析失败默认按 `continue` 放行（`:44`），且仅在有失败步骤时才对用户告警（`stageGateBypassWarning`，`:70`）。
- 子 Agent 交互代答：`group_interaction_handler.dart:229`。
- 派发对象与顺序：admin 每轮自行决定。

### 2.3 编译期 flag（8 个，全部 `true`）

`lib/services/group/group_orchestration_features.dart`：`structuredTasks`、`requirePublishedPlan`、
`reconFirstBounce`、`maxReconFirstBounces`、`adminHistoryScope`、`structuredResults`、
`pendingAdminWake`、`stalledTimeout`、`sessionHandoffHint`。
注释自称 "Defaults favor the new structured-task path" —— 是灰度残留，不是配置项。

### 2.4 文档与代码不一致（已于 2026-09-11 清理）

曾存在的问题：`docs/USER_GUIDE.md` 承诺「三种群组编排模式」，但：
- 代码中只有 `bool flowMode`，没有三态枚举；
- Planning Mode 的 `planning_mode` 列已废弃（`channel_dao.dart:48`、`753` 注释 deprecated）；
- 只剩 i18n 文案 `chat_planningMode`，无任何 UI 引用；
- 计划数据结构本身仍被 Flow Mode 复用（`planning_models.dart`、`message_bubble.dart` 里的 `PlanApprovalCard`）。

同一错误还散落在 `README.md`、`README_CN.md`、`README_EN.md`、`USER_GUIDE_EN.md`、
以及 `assets/skills/app-usage-guide/references/02-user-operations.md`。最后一份会被 agent
直接读到，等于在教 agent 一个不存在的开关——优先级最高。

**已清理**：全部改为「两种编排模式（标准 / Flow）」，计划审批作为 Flow 内的计划卡片描述；
两个无引用的 arb key（`chat_planningMode`、`chat_planningModeDesc`）已从 `app_zh.arb` /
`app_en.arb` 移除并重新 `flutter gen-l10n`。

### 2.5 计划模式其实已经存在，且群聊单聊共用一套引擎

调研发现「先出计划 → 用户确认 → 执行」并非群聊独有，底层是同一套 workflow 引擎：

- **She 的 1:1 私聊已启用**：`chat_controller_load.dart:90-92`
  ```dart
  // She 私聊启用 DM 工作流（自规划自执行）；其他 DM（普通 agent、
  // 绑定中继会话）不启用。
  dmWorkflowEnabled = channel.agentIds.contains(SheService.sheId);
  ```
- 群聊 Flow Mode 与 She 私聊走同一条路径，`workflow_create_command.dart:25`：
  "群聊 Flow Mode 与 She 的 1:1 私聊一致"。
- **审批卡片与会话类型无关**：`message_bubble.dart:1063-1075` 由
  `message.metadata['plan_approval']` 驱动渲染 `PlanApprovalCard`，无 `channel.type` 分叉。
- **存储与会话类型无关**：`workflow_executions` / `workflow_step_executions` 按 `channel_id`
  存，`WorkflowService.getActiveWorkflow(channelId)` 不区分 dm / group。
- **工具分两层**：`shepaw workflow create/dispatch/status/complete/fail/cancel`
  （`shepaw_cli.dart:76`）是通用 CLI，任何开了 `includeShepawCli` 的 agent 都能调，无 type 分叉；
  而 `group_plan_publish` / `group_dispatch` / `group_mention` 等（`group_orchestration_tools.dart:16-18`）
  是群聊专属，仅注入 admin。

结论：**门控不是按 `channel.type`，而是按「成员里有没有 She」**。把计划模式扩展到单聊，
实质上是把这条判据换成一个用户开关，而不是新建一套机制。

## 3. 决策原则

**判据：用户能在「按下发送之前」回答这个问题吗？**

| 归属 | 判据 | 理由 |
|---|---|---|
| **用户开关** | 事前可判断，且选错代价高、事后难改 | 用户有明确意图，错了要整轮重跑 |
| **Admin 自主** | 事前无法判断，必须看到成员实际输出才知道 | 用户发起时无从选择，只有 admin 有上下文 |
| **编译期 flag** | 两者都不是——纯实现细节或灰度 | 用户既看不懂也无从选择，进 UI 就是噪音 |

补充原则：**开关是「授权条」而不是「模式」**。凡是限制 admin 自主权边界的旋钮
（比如"允不允许 admin 替我中止流程"），必须留给用户——它约束的是 admin 能替用户做多少决定，
而不是替 admin 做决策。

## 4. 逐项裁决

| 项 | 裁决 | 说明 |
|---|---|---|
| `mentionMode` | **保留开关** | 群的"社交契约"，决定谁能被 @，影响所有成员的行为预期。用户事前明确知道。 |
| `maxLoopRounds` | **保留开关** | 成本上限，纯用户侧约束（烧多少 token）。 |
| `flowMode` | **保留开关，但挪位置** | 见 §5.2：它是每次任务的属性，不是群的属性。 |
| `enableStageGate` | **保留，语义摆正** | 见 §5.3：从"模式"改称"干预强度"，三档。 |
| 计划模式 | **保留，并扩展到单聊** | 见 §5.1：它不是第三种编排模式，而是正交于编排模式的审批闸门。 |
| 8 个 feature flag | **不进 UI，收敛删除** | 见 §5.4。 |
| 新增编排策略 | **默认归 admin** | 除非能通过 §3 判据，否则不许加 UI 开关。 |

## 5. 落地步骤（按顺序）

### 5.1 计划模式：保留，正交化，并扩展到单聊（已拍板）

#### 5.1.1 重新定位：它是「审批闸门」，不是第三种编排模式

原文档把「标准 / Planning / Flow」并列成三种模式，这是个分类错误。
「先出计划给你看，你点头再执行」与「怎么编排多个 agent」是两个正交的维度：

|  | 不卡审批（直接跑） | 卡审批（计划模式） |
|---|---|---|
| **标准编排**（轮流对话） | 现状默认 | 群聊：admin 先给讨论提纲，确认后再开始 |
| **Flow 编排**（阶段化执行） | 现状 `flowMode` | FlowPlan 生成后先给用户过一遍 |

所以计划模式应当是一个**独立的 bool 开关**，而不是 `Channel` 上的三态枚举。
这也让单聊支持它变得自然——单聊没有多 agent 编排，但仍然可以"先出计划 → 你确认 → 执行"。

统一后的命名建议：内部沿用 `planApproval`（与 `metadata['plan_approval']` 一致），
UI 文案用「计划确认」。原 `chat_planningMode` arb key 无人引用，已删除（见 §5.1.3）。

#### 5.1.2 扩展到单聊：换掉判据，不是新建机制

现状门控在 `chat_controller_load.dart:90-92`：只有成员含 She 的 DM 才有工作流。
改造点：

1. **判据换掉**：`dmWorkflowEnabled` 从「`channel.agentIds.contains(SheService.sheId)`」
   改为「用户开了计划模式开关 **且** 该 agent 支持 shepaw CLI」。
   开关落到 `Channel`（参照 `enableStageGate` 的持久化路径：`copyWithGroupEdit` / `toJson`）。
2. **复用现有三件套**：`WorkflowService.createWorkflowExecution` +
   `PlanApprovalCard` + `WorkflowProgressPanel`，都已经 type-agnostic。
   UI 门控点 `chat_screen.dart:3699,3730` 的 `c.isGroupMode || c.dmWorkflowEnabled`
   保持结构不变，只是 `dmWorkflowEnabled` 的含义变了。
3. **补两个单聊缺口**：
   - `chat_controller_load.dart:231-234`：DM 缺 `_reattachPendingPlanApproval`
     （DM 靠 metadata 持久化，没有 Completer），重载会话时待审批计划可能丢。
   - `WorkfowStep.agent` 在单聊无意义（`chat_controller_workflow.dart:327-333` 已处理
     DM 回合竞态），需补执行人缺失时的降级——单 agent 串行执行。

#### 5.1.3 同步清文档债 ✅ 已完成（2026-09-11）

全部改为「两种编排模式（标准 / Flow）」，计划审批不再作为独立模式出现，
而是 Flow 里的「计划卡片 → 你确认 → 执行」。改动文件：

- `assets/skills/app-usage-guide/references/02-user-operations.md`（优先，会被 agent 读到）
- `docs/USER_GUIDE.md` / `docs/USER_GUIDE_EN.md`
- `README.md` / `README_CN.md` / `README_EN.md`
- `docs/gorup_chat_flow.md`（`planningMode` 开关 → `flowMode`）
- `lib/l10n/app_zh.arb` / `app_en.arb` + 重新 `flutter gen-l10n`

注：用户文档只写**现状**。计划模式作为「正交维度」的写法只出现在本决策文档（§5.1.1），
等 §5.1.2 落地后再同步到用户文档。

### 5.2 `flowMode` 从「群属性」下沉到「本次任务属性」

现状：改一次要开抽屉 → 编辑群信息 → 翻开关 → 保存。链路太长，实际没人来回切，
于是群被永久锁定在一种模式上。

同一个群有时想讨论、有时想直接跑——模式是**每次发送时的意图**，不是建群时的一次性选择。

做法（渐进）：
1. 群详情页的开关降级为「默认运行方式」（保留向后兼容，语义改为默认值）；
2. 输入框侧提供一次性的运行方式选择，覆盖本次任务；
3. 观察使用数据后，再决定是否移除群级开关。

### 5.3 `enableStageGate` 改为「干预强度」三档

它现在是个 bool，但实质在问"你接受 admin 替你做多少决定"。改成枚举：

| 档位 | 行为 |
|---|---|
| `auto`（默认） | admin 全权，不打断，结束后给一份报告 |
| `gate` | 每个阶段结束阻塞等 admin 决策（= 现在的 `enableStageGate = true`） |
| `askUser` | 阶段结束阻塞等**用户**确认，admin 只给建议 |

注意 `GroupOrchestrationFeatures` 目前是 `static bool` 全局态，若三档要可配置需落到
`Channel` 上（走 `copyWithGroupEdit` / `toJson`，参照现有 `enableStageGate` 的持久化路径）。

### 5.4 收敛 8 个 feature flag

`group_orchestration_features.dart` 现在全部 `true`，等于没有开关。逐个决定：
行为已稳定 → 删除 flag、把代码路径写死；仍需灰度 → 保留但补上移除时间点。
不要把它们搬到 UI。

## 6. 待定

1. 单聊计划模式的开关放在哪一层：跟 `flowMode` 一样做成 `Channel` 属性（群/单聊各自一份），
   还是像 §5.2 说的做成「每次发送时的意图」？**倾向后者**，但要先看 §5.2 是否落地。
2. 单聊计划模式是否对**所有** agent 开放，还是只给开了 `includeShepawCli` 的？
   纯聊天型 agent（没开 CLI）调不了 `shepaw workflow create`，开了开关也没用——
   UI 上要不要拦（开关置灰 + 说明）？
3. `flowMode` 下沉到每次发送，是否值得做（§5.2 第 2 步改造量不小）。
4. 干预强度三档里 `askUser` 这档是否真有需求——如果没人用，两档就够。

## 7. 已拍板

| # | 决策 | 日期 |
|---|---|---|
| 1 | 计划模式保留，不删除；且不止群聊，单聊也要支持 | 2026-09-11 |
| 2 | 计划模式重新定位为「审批闸门」，与编排模式正交，不当作第三种模式 | 2026-09-11 |

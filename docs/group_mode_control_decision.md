# 对话模式控制权归属：决策记录（群聊 + 单聊）

> 状态：§5.1 已重新拍板（规划模式 = 只读开关，映射到 agent 原生 plan mode），其余待确认
> 日期：2026-09-11
> 更新 1：补入单聊 workflow 引擎调研（§2.5）
> 更新 2：文档债已清（§2.4、§5.1.4）
> 更新 3：**§5.1 定位修正** —— 初版把「计划模式」理解成 App 侧审批闸门，理解错了。
> 用户要的规划模式是「一个开关让 agent 别动手改代码，先写计划」，见 §5.1.1。
> 原决策 #1 / #2（§7）作废。

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

> ⚠️ 这套引擎是**审批闸门**（App 拿结构化计划驱动执行），**不是**用户要的规划模式。
> 见 §5.1.1 的修正。这里保留是因为它是现状事实，但不要再把它当作规划模式的落地路径。

### 2.6 第三方 agent 的原生 plan mode

Shepaw 接入的远端 agent（Claude Code、Codex、Cursor 等）自带 plan mode。
调研结论：

- **项目里已经有映射表**：`lib/peer/engine_session_modes.dart:38-74` 硬编了各引擎的原生 mode，
  其中 `claude-code/plan`、`cursor/plan`、`opencode/plan` 的描述统一是「只规划，不改代码」；
  `codex` 是审批档位（`on-request` / `on-failure` / `never`）。
- **但只对 Peer（Hub 引擎）开放**：`remote_agent_detail_screen.dart:357`
  `if (!_agent.isPeerAgent) return;` —— ACP 远端 agent 用不上。
- **ACP 侧没有能力协商**：`acp_protocol.dart:187-336` 全部 method 里没有 `plan` /
  `session_mode` / `permission`；capability 只解析一个 bit ——
  `acp_agent_connection.dart:2014` `_supportsAsyncConfirmation = capsSet.contains('async_confirmation')`。
- **因此会双计划并存**：`group_prompt_builder.dart:1201` 无条件教 ACP 管理员
  「调用 `shepaw workflow create` 创建工作流」，而对端自己的 plan mode 同时也在跑，
  两条路产出的东西互不可见。
- **本地裸模型没有原生 plan mode**：本地 LLM 代理就是 OpenAI 兼容接口，只有 prompt 可约束。

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
| 规划模式（新） | **新增开关** | 见 §5.1：一个「别动手改代码，先写计划」的只读开关，映射到 agent 原生 plan mode。 |
| 老的 Planning Mode | **删** | 见 §5.1.2：代码里已无剩余物，文档债已清。 |
| 审批闸门（workflow） | **维持现状，不扩展** | 见 §5.1.1：那是另一件事，原「扩展到单聊」的计划已搁置。 |
| 8 个 feature flag | **不进 UI，收敛删除** | 见 §5.4。 |
| 新增编排策略 | **默认归 admin** | 除非能通过 §3 判据，否则不许加 UI 开关。 |

## 5. 落地步骤（按顺序）

### 5.1 规划模式：一个「只读规划」开关（2026-09-11 重新拍板）

#### 5.1.1 修正：上一版定位错了

上一版把「计划模式」理解成 App 侧的**审批闸门**（先出计划 → 用户确认 → App 驱动执行）。
这不是用户要的。用户要的规划模式很单纯：

> 一个开关，让 agent 不要动手改代码，先写计划。

两者是根本不同的东西：

|  | 审批闸门（上一版的理解） | 规划模式（用户要的） |
|---|---|---|
| 重点 | 「我来批准」 | 「你不许动手」 |
| 机制 | App 拿结构化计划渲染卡片，用户点头后 App 驱动执行 | agent 处于只读状态，只输出计划 |
| 强制力 | App 侧编排 | **agent 侧工具权限，硬拦** |
| 产物 | `workflow_executions` 里的结构化步骤 | 一段计划文本 |
| 承载 | workflow 引擎（§2.5） | **agent 原生 plan mode**（§2.6） |

所以规划模式**不是** workflow 引擎的事，而是**把 agent 原生的「只读规划」能力暴露成一个开关**。
原 §5.1.2「扩展到单聊」那套改造（换 `dmWorkflowEnabled` 判据）属于审批闸门路线，
**已搁置**，不再是规划模式的落地路径。

#### 5.1.2 老的 Planning Mode：删（代码里已无剩余物）

文档债已清（§5.1.4）。代码侧复查一遍，确认没有可删的剩余物：

- `planning_mode` 列：已 deprecated，仅为迁移兼容保留（`channel_dao.dart:48`、`:753`）。
  **保持不动**——删列要写迁移，收益为零。
- `planning_models.dart`：**不是**老 Planning Mode 的残留，而是 Flow / Workflow 共用的
  计划数据结构，被 `workflow_service.dart`、`plan_approval_card.dart`、
  `workflow_create_command.dart` 使用，**不能删**。
  只是文件名带 `planning_` 容易误导，可考虑改名，纯重命名，优先级低。

结论：老的 Planning Mode 在代码里早就死透了，「删」这件事实际只落在文档上，已完成。

#### 5.1.3 新的规划模式：映射到 agent 原生 plan mode

§2.6 已确认：**项目里已经有第三方原生 plan mode 的映射表**，正是这个语义。

- `lib/peer/engine_session_modes.dart:38-74`：`claude-code/plan`、`cursor/plan`、
  `opencode/plan`，描述统一为「只规划，不改代码」。
- 关键优势：**原生 plan mode 是硬拦**。Claude Code 的 plan mode 真的把写工具禁掉，
  agent 想违规也做不到。这比 Shepaw 用 prompt 说「请先写计划」可靠得多——
  后者是软约束，模型不守规矩就绕过。
- 现状只对 Peer（Hub 引擎）开放：`remote_agent_detail_screen.dart:357`
  `if (!_agent.isPeerAgent) return;`

落地步骤：

1. 把 mode 选择器从 Peer-only 放开到 ACP 远端 agent（去掉上面那道门）。
   前提：要能拿到 engineId，ACP 侧目前拿不到，需要先补。
2. 开关语义统一叫「规划模式」，不管背后映射的是原生 plan mode 还是别的。
3. 中期：ACP 握手加 native plan capability 协商位（`acp_protocol.dart:187-336` 目前没有），
   有原生能力就映射过去；没有再决定降级策略。

#### 5.1.4 清文档债 ✅ 已完成（2026-09-11）

全部改为「两种编排模式（标准 / Flow）」，计划审批不再作为独立模式出现，
而是 Flow 里的「计划卡片 → 你确认 → 执行」。改动文件：

- `assets/skills/app-usage-guide/references/02-user-operations.md`（优先，会被 agent 读到）
- `docs/USER_GUIDE.md` / `docs/USER_GUIDE_EN.md`
- `README.md` / `README_CN.md` / `README_EN.md`
- `docs/gorup_chat_flow.md`（`planningMode` 开关 → `flowMode`）
- `lib/l10n/app_zh.arb` / `app_en.arb` + 重新 `flutter gen-l10n`

注：用户文档只写**现状**。规划模式是新能力，等 §5.1.3 落地后再同步到用户文档。

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

1. **本地裸模型（没有原生 plan mode）怎么办？** 三条路：
   - 只靠 prompt 软约束（「先给计划，等我确认再动手」）—— 不保证，模型可能照改不误；
   - 开关置灰，只对有原生 plan mode 的 agent 开放 —— 诚实，但本地 agent 用户用不上；
   - 置灰 + 说明「该 agent 不支持，只能靠提示词约束」。
   **倾向第三条**，但要确认本地 LLM 代理是不是重要场景。
2. 规划模式的开关放在哪一层：做成 `Channel` 属性（跟 `flowMode` 一样），
   还是做成「每次发送时的意图」（§5.2 的路子）？规划模式更像**会话级状态**
   （一次规划可能跨好几轮），**倾向 `Channel` 属性**。
3. ACP 远端 agent 的 engineId 从哪来？`engineSessionModeCatalog(engineId)` 需要它，
   目前只有 Peer 路径有。这是 §5.1.3 第 1 步的前置。
4. 群聊里规划模式作用于谁？只约束 admin、还是所有成员？群聊语义下「别动手」
   应该约束的是**成员**（干活的），admin 本来就在协调。
5. `flowMode` 下沉到每次发送，是否值得做（§5.2 第 2 步改造量不小）。
6. 干预强度三档里 `askUser` 这档是否真有需求——如果没人用，两档就够。

## 7. 已拍板

| # | 决策 | 日期 |
|---|---|---|
| 1 | ~~计划模式保留，不删除；且不止群聊，单聊也要支持~~ **作废**（定位错了） | 2026-09-11 |
| 2 | ~~计划模式重新定位为「审批闸门」，与编排模式正交~~ **作废**（同上） | 2026-09-11 |
| 3 | 老的 Planning Mode 删除；代码侧无剩余物，只清文档 | 2026-09-11 |
| 4 | 规划模式 = 一个「别动手改代码，先写计划」的只读开关，映射到 agent 原生 plan mode | 2026-09-11 |
| 5 | 审批闸门（workflow 引擎）与规划模式是两件事；前者维持现状，不再扩展到单聊 | 2026-09-11 |

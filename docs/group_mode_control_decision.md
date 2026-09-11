# 对话模式控制权归属：决策记录（群聊 + 单聊）

> 状态：§5.1 已重新拍板（规划模式 = 只读开关，映射到 agent 原生 plan mode），其余待确认
> 日期：2026-09-11
> 更新 1：补入单聊 workflow 引擎调研（§2.5）
> 更新 2：文档债已清（§2.4、§5.1.4）
> 更新 3：**§5.1 定位修正** —— 初版把「计划模式」理解成 App 侧审批闸门，理解错了。
> 用户要的规划模式是「一个开关让 agent 别动手改代码，先写计划」，见 §5.1.1。
> 原决策 #1 / #2（§7）作废。
> 更新 4：**会话模式入口已落地**（2026-09-12）。§5.1.5 的位置与 §5.1.6 的
> 「会话模式」一行已实现（输入框 chip + Shift+Tab），模型入口仍未做（§6 #8）。

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

**⚠️ 关键阻塞：mode 的传输通道只存在于 Peer 协议，ACP 没有。**

- `metadata['engine']` 只有 peer 路径会写：`peer_agent_client_service.dart:3858`（从配对设备拉取
  agent 列表时）、`peer_agent_host_service.dart:357`（本机 agent 分享给 peer 时）。
  **ACP 远端 agent 的 `metadata['engine']` 永远是 null** → 查不到 catalog。
- `lib/models/acp_protocol.dart` 里 `grep modes` **零命中**——ACP 协议没有任何 mode 相关方法。
  mode 的读写只有 peer 那套：`agent.modes.list` / `agent.modes.setCurrent`
  （`peer_agent_client_service.dart:1859` / `:1905`）。
- `shepaw-acp-proxy` **不在这个仓库**（另一个二进制/仓库），要加协议方法得跨仓库协同。

结论：单纯去掉 `remote_agent_detail_screen.dart:357` 那道 `if (!_agent.isPeerAgent) return;`
只会得到一个「选了没反应」的下拉框。缺的不是 UI 门，是传输通道。

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

#### 5.1.3a 原落地步骤第 1 步作废（2026-09-11 查证）

原计划「把 mode 选择器从 Peer-only 放开到 ACP 远端 agent」**不可行**，见 §2.6 末尾：
ACP 协议没有 mode 方法、`metadata['engine']` 也拿不到，去掉 UI 门只会得到无反应的下拉框。

#### 5.1.3b 修订后的落地顺序

**阶段一：App 侧闭环（不依赖外部仓库，可立即做）**

1. 规划模式开关 UI + 会话状态，按 §5.1.5 落地。✅ **已完成**（2026-09-12）
2. 生效路径按能力分级：
   - **Peer agent** → 已有 `setMode` transport，直接映射原生 plan mode。✅ 硬拦
   - **ACP 远端 agent** → 无 transport，降级为 prompt 注入（软约束），UI 明示「该 agent
     不支持原生规划模式，仅靠提示词约束」
   - **本地裸模型** → 同上，待 §6 #1 定夺
3. 能力判定：新增一个 `supportsNativePlanMode` 判定，Peer + `metadata['engine']` 命中
   catalog 且含 `plan` 档 → true；否则 false。

**阶段二：ACP 协议扩展（跨仓库，独立提案）**

4. `acp_protocol.dart` 加 mode 相关方法 + 握手 capability 位，需要 `shepaw-acp-proxy`
   同步实现。做完后阶段一的降级路径自动升级为硬拦。

**会话级是对的，transport 本来就支持。** 初版曾据函数签名推断 `setMode` 是 agent 级，
这是错的——漏看了可选参数：

- `fetchModes({peerId, remoteAgentId, sessionId})`（`peer_agent_client_service.dart:1863`）
  和 `setMode({peerId, remoteAgentId, mode, sessionId})`（`:1909`）**都接受 `sessionId`**，
  传了就写进 `payload['session_id']`。文档注释也写明「[sessionId] scopes to a synced session」。
- 类型与命名本身就是会话语义：`PeerAgentMode` 的注释是「One upstream **session-mode**
  option」，relay 的目标方法叫 `agent.modes.list` / `agent.modes.setCurrent`。
- 第三方 agent 的 plan mode 本来就是 per-session（Claude Code / Cursor 都能多会话并行，
  一个在规划、另一个在执行）。做成 agent 级反而不能并行开发。

**当前之所以表现得像 agent 级，是调用方的问题**：Agent 详情页的
`_loadPeerModes()`（`remote_agent_detail_screen.dart:387`）调 `fetchModes` 时**没传 sessionId**。
是那个页面的用法是 agent 级的，不是能力是 agent 级的。

结论：规划模式的开关做成**会话级**（§5.1.5）与 transport 一致，
切换时把本会话对应的远端 sessionId 传下去即可，不需要额外记录每个会话的 mode。

#### 5.1.5 开关放哪：输入框工具条，不放设置页（2026-09-11 定）✅ 已落地（2026-09-12）

**结论：输入框上的常驻切换 + 状态挂在会话（Channel）上。**

三条理由：

1. **切换频率高。** 规划模式是「这个任务先规划还是直接干」，一个任务里可能来回切好几次。
   参照 §5.2 对 `flowMode` 的同一个论证：放群详情页要「开抽屉 → 编辑 → 翻开关 → 保存」，
   实际没人切，会话就被永久锁在一个状态上。
2. **它是当前状态，不是配置。** 配置页的开关做完就看不见了；规划模式必须**常驻可见**——
   否则用户会忘了自己还开着，以为 agent 卡住不动。
3. **它跨轮。** 写计划 → 你反馈 → 改计划 → 你确认，是一次对话里的多轮状态。
   所以不是「每次发送时的一次性选择」，得挂在会话上。

具体落点（`lib/widgets/chat/chat_input_area.dart`）：

| 端 | 位置 | 说明 |
|---|---|---|
| 桌面 | 底部工具条那排，emoji / 附件图标旁（`chat_input_area.dart:1819-1851`） | 现在是两个图标 + Spacer + 发送，位置够 |
| 移动 | 输入框**上方**一条状态条 | 那一行已经塞了 语音 / + / 输入框 / 发送（`:2288-2367`），再塞图标会挤。参照 `_buildPendingAttachmentsPreview()`（`:2287`）的先例，做成输入框上方一条 |
| 桌面快捷键 | `Shift+Tab` | `_handleInputKeyEvent`（`:2581`）已有，加一个分支成本极低；跟 Claude Code 一致，肌肉记忆可迁移 |

**用带文字的 chip（「规划中」），不要纯图标。** 工具条小图标一多就认不出来，
而规划模式必须让用户一眼看见当前状态——可见性比省那点空间重要。

打开时给输入框一个可见变化（边框/底色 + hint 文案改成「描述你想做什么，Agent 会先给计划」），
避免「开了但没反馈」的困惑。

**不推荐的位置：**

- 群详情页 / Agent 详情页的开关（`group_detail_screen.dart:806` 那一类）——太深，切不动
- 每次发送时的一次性选择——跨轮，装不下
- 只靠 slash 命令——依赖 agent 自己暴露 `/plan`，不是统一入口；可以作为**补充**（现有 slash
  机制见 `SlashCommandPicker`），但不能当主入口

**落地结果**（2026-09-12，`lib/widgets/chat/chat_input_area.dart`）：做成了**会话模式 chip**
而不是独立的 bool 开关——plan 只是上游众多档位之一（claude-code 有六档），单开一个 bool 会
变成第二个真相源（见 §5.1.3b 与 `5ccea29` 的 revert）。因此：

- chip 常驻显示当前档位，`plan` 档高亮为「规划中」；点开菜单可切到任意档位；
- Shift+Tab 专用于 plan 档切换，再按一次回原档位；
- 状态不进本地库：`fetchModes` / `setMode` 均带 `sessionId`，按会话生效；换会话清空重拉；
- 群聊暂不显示入口（§6 #4 未定），本地 agent 无上游 mode 也不显示（§5.1.6）。

#### 5.1.4 清文档债 ✅ 已完成（2026-09-11）

全部改为「两种编排模式（标准 / Flow）」，计划审批不再作为独立模式出现，
而是 Flow 里的「计划卡片 → 你确认 → 执行」。改动文件：

- `assets/skills/app-usage-guide/references/02-user-operations.md`（优先，会被 agent 读到）
- `docs/USER_GUIDE.md` / `docs/USER_GUIDE_EN.md`
- `README.md` / `README_CN.md` / `README_EN.md`
- `docs/gorup_chat_flow.md`（`planningMode` 开关 → `flowMode`）
- `lib/l10n/app_zh.arb` / `app_en.arb` + 重新 `flutter gen-l10n`

注：用户文档只写**现状**。规划模式是新能力，等 §5.1.3 落地后再同步到用户文档。

#### 5.1.6 输入框两个入口的数据来源（2026-09-11 定）

**前提：Agent 只有两类。** ACP 远端 agent 已废弃（App 入口已隐藏），只剩
**Peer 接入的 agent**（Hub 引擎）与**本地 agent**（本地 LLM 代理）。

| 入口 | Peer agent | 本地 agent |
|---|---|---|
| 会话模式 | `fetchModes` / `setMode`（`peer_agent_client_service.dart:1863` / `:1909`） | **隐藏** |
| 模型 | `fetchModels` / `setModel`（`:1778` / `:1823`） | `AgentScenarioModels.modelIds`（`agent_scenario_models.dart:10`） |

**两行都已落地**（2026-09-12，均为输入框 chip，与会话模式并排）：

- **会话模式**：走 `fetchModes` / `setMode` 且都传 `sessionId`；本地 agent 判定为
  「非 Peer」→ 整个入口不渲染。
- **模型**：同一个 chip 按 agent 类型取不同数据源 ——
  - 本地 agent → `metadata['main_model_id']` + `ModelRegistry`，菜单带「添加模型」
    直达模型管理页（§6 #8）；
  - Peer agent → 上游 `fetchModels` / `setModel`，按会话下发；没有「添加模型」
    入口（对端自管），离线时整个入口不显示（模型没有引擎目录可兜底）。

**模型列表走的也是 Peer relay，不是 ACP。** `acp_protocol.dart` 里 `grep model`
零命中；`fetchModels` 是 `agent.models.list` relay，与 `fetchModes` 同构，
同样接受可选 `sessionId`（注释：「scoping to a synced session」）。

本地 agent 没有「模型列表」，只有按模态配置的 modelId 映射
（`Map<ModalityType, String>`），picker 需列出其 values。
待定：输入框里的「模型」切的是哪个模态（见 §6 #8）。

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
2. ~~规划模式开关放在哪一层~~ **已定（§5.1.5）**：输入框工具条上的常驻切换 +
   状态挂 `Channel`（会话级）。
3. ACP 远端 agent 的 engineId 从哪来？`engineSessionModeCatalog(engineId)` 需要它，
   目前只有 Peer 路径有。这是 §5.1.3 第 1 步的前置。
4. 群聊里规划模式作用于谁？只约束 admin、还是所有成员？群聊语义下「别动手」
   应该约束的是**成员**（干活的），admin 本来就在协调。
5. ~~`setMode` 是 agent 级还是会话级~~ **已定（§5.1.3b）**：**会话级**。
   `fetchModes` / `setMode` 都接受 `sessionId`，transport 本来就支持；
   看着像 agent 级只是因为 Agent 详情页调 `fetchModes` 时没传 sessionId。
6. `flowMode` 下沉到每次发送，是否值得做（§5.2 第 2 步改造量不小）。
7. ~~ACP 远端 agent 的模型/会话模式入口怎么办~~ **关闭**：ACP 已废弃，App 入口已隐藏，
   只剩 Peer agent 与本地 agent 两类（§5.1.6）。
8. ~~输入框的「模型」切哪个模态~~ **已定**：**复用 Agent 设置页「主模型」的那套下拉**，
   并且要能顺手添加模型。不是按 `ModalityType` 逐个切。**已落地**（2026-09-12）。
   Peer agent 走同一 chip 的上游分支（`fetchModels`），共用 UI、分数据源。

   主模型的落点与取值：
   - 存 `RemoteAgent.metadata['main_model_id']`（`remote_agent.dart:397`）
   - 经 `ModelRegistry.instance.getById(...)` 解析（`:408`）
   - 下拉在 `AgentModelConfigCard`（`agent_model_config_card.dart:158-160`，
     `initialValue: widget.mainModelId`），列表来自 `ModelRegistry` 的全局模型定义
   - 输入框入口点开即同一个 picker + 一个「添加模型」入口（复用
     `ModelSelectScreen` / 模型管理页的添加流程）

   所以本地 agent 与 Peer agent 的模型入口**都**走这套：Peer 额外可先用
   `fetchModels` 拉上游列表，本地直接用 `ModelRegistry` 的已配置定义。
6. 干预强度三档里 `askUser` 这档是否真有需求——如果没人用，两档就够。

## 7. 已拍板

| # | 决策 | 日期 |
|---|---|---|
| 1 | ~~计划模式保留，不删除；且不止群聊，单聊也要支持~~ **作废**（定位错了） | 2026-09-11 |
| 2 | ~~计划模式重新定位为「审批闸门」，与编排模式正交~~ **作废**（同上） | 2026-09-11 |
| 3 | 老的 Planning Mode 删除；代码侧无剩余物，只清文档 | 2026-09-11 |
| 4 | 规划模式 = 一个「别动手改代码，先写计划」的只读开关，映射到 agent 原生 plan mode | 2026-09-11 |
| 5 | 审批闸门（workflow 引擎）与规划模式是两件事；前者维持现状，不再扩展到单聊 | 2026-09-11 |
| 6 | 规划模式开关放输入框工具条（桌面）/ 输入框上方状态条（移动），状态挂会话；快捷键 Shift+Tab | 2026-09-11 |

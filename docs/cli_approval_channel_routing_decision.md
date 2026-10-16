# CLI / OS 审核卡归属路由（修复串台）

## 现象

和某个 agent（如 she）聊天时，它调用需要审批的 OS 工具会生成审核卡
（`CliApprovalCard`）。当用户切到**另一个** agent 的会话页面时，这张卡
直接出现在了当前这个 agent 的气泡流里。

期望：审核卡只属于发起它的那个会话；停留在别的会话时改由 App 顶部横幅
提示，点击后跳回归属会话再审核。

## 现状数据流

1. 发消息：`chat_controller_messaging.dart:948` 传
   `onOsToolConfirmation: requestCliApproval` —— 闭包绑定在**那个
   controller 实例**上，与频道无关。
2. 回合中调 OS 工具：`CliExecutionGate.execute`
   （`lib/services/cli_execution_gate.dart:34`）。群执行 / `hub.cli.execute`
   路径可能不传 `onOsConfirmation` → 落到
   `CliApprovalCoordinator.instance.request`（:190）。
3. 分派：`CliApprovalCoordinator.request` 调 `_handlers.last`
   （`cli_approval_coordinator.dart:47`）—— 即**最后注册 = 当前可见**的
   controller。handler 签名 `(toolName, flags, risk)` **不带任何归属信息**。
4. 插卡：`ChatController.requestCliApproval`
   （`chat_controller_interactions.dart:15`）→ `_insertCliApprovalCard`（:150）
   - `messages.add(...)` → 当前 controller 的列表；
   - `createMessage(channelId: currentChannelId!)`（:248-259）；
   - `PendingApprovalHub.upsert(channelId: currentChannelId!)`（:174-184）。

## 根因

审核请求没有归属标识，路由键是"谁最后注册"。桌面端切换会话是**复用同一个
controller 原位换频道**（`chat_controller_load.dart:280`，注释 :273-279 明确
不 cancel 旧频道回合），于是旧回合的审批回调打到已换频道的 controller 上：

- 卡插进 B 频道的 `messages` 并落库到 B；
- hub item 的 `channelId` 也记成 B → `PendingApprovalBanner._visibleOf`
  （`pending_approval_banner.dart:58-62`）按"等于 activeChannel"把它过滤掉，
  **顶部横幅也永远不出现**。

两处都错：串台 + 全局提示失效。

## 决策

**审核卡的归属由「发起回合的 channelId」决定，不由「当前可见的 controller」
决定。**

### L1 归属信息贯通

审批回调增加归属上下文（`channelId` / `agentId`）。`CliExecutionGate.execute`
本身已经收 `channelId`（:37）与 `agentId`（:36），只需往下传进
`_denyIfUnconfirmed`。

受影响签名（机械改动，App 未发布，不留兼容分支）：

- `lib/services/cli_approval_coordinator.dart:4` typedef
- `lib/services/cli_execution_gate.dart:44-48`、`:152-156`
- `lib/services/task/task_models.dart:115`
- `lib/services/messaging/message_params.dart:23`
- `lib/services/messaging/agent_messaging_service.dart:646`、`:1365`
- `lib/services/chat_service.dart:1182`、`:2517`
- `lib/controllers/chat_controller.dart:710`
- `lib/controllers/chat_controller_interactions.dart:15`
- `lib/controllers/chat_controller_messaging.dart:948`
- `lib/controllers/chat_controller_workflow.dart:360`

### L2 控制器按归属分派

`requestCliApproval` 收到 `channelId` 后二分：

- `channelId == null || channelId == currentChannelId` → 维持现有插卡路径。
- 否则 → **不碰当前 `messages`**，改走"落库 + hub"路径：
  - 复用 `StreamingActionConfirmation.buildFallbackBubble` 造气泡，用
    `localDatabaseService.createMessage(channelId: 归属频道, ...)` 落库；
  - `PendingApprovalHub.upsert` 写**归属频道** → 顶部横幅出现（此时
    activeChannel 是别的频道，`_visibleOf` 不再过滤它）；
  - `CliApprovalService.awaitApproval(channelId: 归属频道)` 等待。用户点横幅
    → `ChatNavigationService.openChannel` → 归属频道 reload 时从 DB 读到卡
    → 点击 → `CliApprovalService.complete`。
  - `CliApprovalService.defaultTimeout` 是 `Duration.zero`（无限等），跨频道
    等待不会被误判为拒绝。

跨频道场景没有活跃流式气泡可挂，卡片一律用 fallback 独立气泡。

### L3 Coordinator 按频道路由 + 兜底

`CliApprovalCoordinator` 从 `List<handler>` 改为按频道登记：

- `register(handler, {channelId})`，controller 在 `loadMessages` /
  `switchChannel` 后更新自己负责的频道；
- `request(..., {channelId})` 命中则转发；未命中不再直接 `return false`
  （那会让群 / headless 回合被就地拒绝），改为走与 L2 相同的"落库 + hub"
  兜底路径。

### L4 顺带修

`_insertCliApprovalCard`（:174-184）里 hub item 的 `channelId` 必须取归属
频道而非 `currentChannelId`，否则横幅判定依旧错。

## 排查结论：归属 channelId 处处可得

原本担心"拿不到频道上下文"的三个调用点，实际全部能拿到：

| 调用点 | channelId |
|---|---|
| `hub_cli_execute.dart:137` | 已经传（`scopeOf` 解析，:140）✅ |
| `group_agent_executor.dart:713` | 已经传（:716）✅ |
| `hub_event_client.dart:351` | `_renderInteraction` 形参就有（:337），未往下传 ❌→补 |

`agent_messaging_service.dart:1465` 的 `os_tool` 交互路径，`sendChatMessage`
作用域内也有 `channelId`（:1444）和 `agent.id`。

**因此不存在"拿不到归属"的合法路径。** 按用户裁定：**不保留任何退回
"当前 channel"的兜底**。签名上把 `channelId` / `agentId` 设为**必填命名参数**，
让编译器强制每个调用点显式给归属——漏传就是编译错误，而不是静默串台。

## 同类串台排查（扩大范围）

`PlanApprovalCard` / `RelayApprovalCard` **无此问题**：两者都是
message-metadata 驱动（`message_bubble.dart:1108-1120`、`:263-265`），卡片渲染
在消息所在的频道里，不存在"插进当前 controller 列表"的动作。

但同一形态的 bug 还有三处（都由流式回调触发，闭包绑在 controller 实例上，
落库用 `currentChannelId`）：

1. `_handleStreamingActionConfirmation`
   （`chat_controller_messaging.dart:1202`）—— 无宿主气泡时
   `messages.add`(:1240) + `createMessage(channelId: currentChannelId!)`(:1256-1269)；
   有宿主时 `updateMessageMetadata(streamingId, ...)`(:1311)，`streamingId`
   解析自当前列表。
2. `_handleStreamingForm`（`:1321`）—— `messages.add`(:1360)，同形。
3. `_handleGroupStreamingInteraction`（`:1442`）—— 群 peer 交互 fallback，同形。

绑定点：`onActionConfirmation: _handleStreamingActionConfirmation`
（`:103`、`:954`，发消息时捕获，作用域内有 channelId）与孤儿审批监听
（`chat_controller.dart:597-620`，只按 `agentId` / `groupAgents` 过滤，**不按
频道**）。

## 实施步骤（分轮提交）

### 第 1 轮：CLI / OS 审核（本次报的 bug）

1. L1 签名贯通：`channelId` / `agentId` 设为必填命名参数。改动点见上表 +
   `cli_approval_coordinator.dart:4`、`cli_execution_gate.dart:44-48`、
   `:152-156`、`task_models.dart:115`、`message_params.dart:23`、
   `agent_messaging_service.dart:646`、`:1365`、`chat_service.dart:1182`、
   `:2517`、`chat_controller.dart:710`、
   `chat_controller_interactions.dart:15`、
   `chat_controller_messaging.dart:948`、
   `chat_controller_workflow.dart:360`。
2. 补 `hub_event_client.dart:351` 传 `channelId`。
3. L3：`CliApprovalCoordinator` 改 `Map<channelId, handler>`，controller 在
   `loadMessages` / `switchChannel` / `dispose` 时登记与注销。
4. L2 / L4：controller 收到非本频道的归属 → **不碰 `messages`**，走
   「落库到归属频道 + hub」；hub item 一律记归属频道。
5. 无 UI 兜底（归属频道当前没有 controller）：DB 写卡 + hub 提醒 +
   `CliApprovalService.awaitApproval` 全局等。用户点横幅跳回归属频道，
   从 DB 读到卡再点 → `complete`。**不是**退回当前 channel。
6. 补测试 + 跑 `test/services`、`test/controllers` 子集比对基线。

### 第 2 轮：流式审核卡 / 表单（同类，另行提交）

同一套归属路由套用到 `_handleStreamingActionConfirmation` /
`_handleStreamingForm` / `_handleGroupStreamingInteraction`，以及孤儿审批
监听（孤儿事件只有 `peer_id` + `remote_agent_id`，需要补 agentId→channelId
的解析，本轮先不动）。

## 第 1 轮实施结果

- 落库路径不需要 userId / userName —— `createMessage` 只认 sender（agent），
  卡片渲染也不依赖 `to`。风险 1 解除。
- 新增 `lib/services/approval/cli_approval_card.dart`：造卡 + 落库到归属频道 +
  写 hub + 等作答，controller 与 coordinator 共用。
- 新增 `test/services/cli_approval_routing_test.dart`：归属路由 / 换频道重登记
  / 无归属拒绝。
- `hub_event_client.dart:351` 补传 `channelId`。

### 唯一仍在的「无归属」路径

`HubCliExecute.run`（`hub_cli_execute.dart:172`）在 ACP agent 没带 `session_id`
且没有在途回合时 `channelId` 为 null。此时确实没有会话可以放这张卡，按裁定
**拒绝 + 告警日志**（`cli_approval_coordinator.dart` / `requestCliApproval`），
不退回当前会话。

## 风险

1. 跨频道落卡后，切回归属频道要能被 `loadMessages` 正常读到并渲染可点态，
   且不被 `_expireStaleCliApprovalCards` 误伤 —— 代码路径已核对（等待中的
   Completer 是 live 的，不会被判过期），但仍需真机冒烟。
2. 跨频道落卡后，切回归属频道要能被 `loadMessages` 正常读到并渲染可点态，
   且不被 `_expireStaleCliApprovalCards` 误伤——需实测。

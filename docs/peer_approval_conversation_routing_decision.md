# Peer 审核 / 表单卡串到群聊（单聊的卡被群认领）

> 定位：本文档是 `docs/cli_approval_channel_routing_decision.md` 留下的**第 2 轮**
> （该文件末尾：「孤儿审批监听只按 `agentId` / `groupAgents` 过滤，不按频道」，
> 「需要补 agentId→channelId 的解析，本轮先不动」）。
> 本轮调查发现该路径不仅有「缺少归属解析」的设计缺口，还有一个**现成的 id 口径
> bug**：单聊分支的过滤条件恒不成立，单聊永远收不到卡，卡被群独占。

## 现象

和 `cursor` 单聊时，agent 触发的审核确认消息（工具审批 / 提问表单）没有出现在
单聊，而是出现在了**群聊**里，发送人显示为群成员 `cursor`。

## 结论速览

| | 结论 |
|---|---|
| 直接根因 | `chat_controller.dart:633` / `:662` 用 `peerAgentLocalId()`（返回 Hub 短名，`shepaw-cursor`）与 `agentId`（本机行 id，存量是 `peeragent_<peer>_<remote>`）比较 → **恒不相等 → 单聊永远不认领** |
| 为什么是群 | 群分支用 `matchGroupPeerAgent()`（`peer_agent_ids.dart:32`）比的是 `metadata.remote_agent_id`，与行 id 无关 → **群照常命中** → 卡被写进群频道，sender = 群成员 cursor |
| 引入点 | commit `392148e1`（2026-09-30，「App 只经 peer 认 Hub Agent，行 id 不再退回旧名」）删掉了 `legacyPeerAgentLocalId` / `decidePeerAgentRowId`，但**存量行没有迁移** |
| 结构性缺口 | 卡帧（`agent_approval_req` / `agent_form_req`）**没有任何会话字段**，App 只能按 agent 身份认领，群 Controller 无从判断这张卡属于单聊还是本群 |
| 触发前提 | 卡到达时单聊已无活动 turn（`agent_done` 竞态 / 主机重连补发 / 单聊页未挂载），走进**孤儿流**；有活动 turn 时走 pending 回调，不会串 |

## 现状数据流

1. **主机造卡**（都不带会话归属）：
   - 工具审批 `agent_approval_req`：`crates/engines/src/stdio.rs:2515-2524`
     —— 只有 `approval_id` / `request_id` / `agent_id`。
   - 提问表单 `agent_form_req`：`crates/api/src/engine_ask.rs:86-93`
     —— 同样只有 `approval_id` / `request_id` / `agent_id`。
   - 对照：主机侧 `TurnRef` **本来就有 `session_id`**
     （`crates/api/src/active_turns.rs:29-34`），只是没写进卡帧。
2. **主机投递**：`engine_ask.rs:97` 先进本轮流，`:101` 再 `broadcast(skip_owner)`
   发给所有已登录设备；重连补发 `pending_frames()` 也不按设备过滤
   （CLI 侧调查结论，行号未逐行核对）。
3. **App 收卡**：`PeerAgentClientService._onApprovalReq`
   （`lib/peer/services/peer_agent_client_service.dart:7147`）
   - 有 pending turn → 回调 `onActionConfirmation`（挂在发起回合的 controller 上，正常显示）；
   - `pending == null` → **孤儿**：`:7254-7262` 往 `orphanApprovalEvents`
     广播一条只带 `peer_id` + `remote_agent_id` 的事件。
4. **App 消费**（`lib/controllers/chat_controller.dart:606-663`，行号为修复前）：
   - 群分支（`:614-626` / `:642-654`）：`matchGroupPeerAgent()` 命中 →
     `_handleGroupOrphanPeerApproval`（`chat_controller_messaging.dart:1561-1625`）
     → 写 `currentChannelId`（= 群）、`senderId = member.id`、
     `updateMessageMetadata` 落库 + `PendingApprovalHub.upsert(channelId: currentChannelId)`。
   - DM 分支（`:633` / `:662`）：`if (peerAgentLocalId(peerId, remoteId) != agentId) return;`

## 根因 A：DM 过滤的 id 口径与存量库不符（决定性）

`lib/peer/services/peer_agent_ids.dart:4`：

```dart
String peerAgentLocalId(String peerId, String remoteAgentId) => remoteAgentId;
```

实测本机库 `~/Library/Application Support/ShePaw/shepaw.db`：

```
agents.id                     = peeragent_86e587a9-158c-4a0e-8529-902faf571dc4_shepaw-cursor
agents.metadata.remote_agent_id = shepaw-cursor
```

单聊频道 id 用的就是带前缀的行 id（实测）：

```
dm_peeragent_86e587a9-158c-4a0e-8529-902faf571dc4_agent-bridge-cursor1_user_1787788424400
```

→ 单聊 `ChatController.agentId` = `peeragent_..._shepaw-cursor`，而过滤比较的是
`shepaw-cursor`，**永远不等，永远 return**。

同一文件里还有一处对照：`_drainPendingOrphanForms`
（`chat_controller.dart:682-703`）不走 `peerAgentLocalId`，而是从 DB 读 agent 行取
`sourcePeerId` + `remoteAgentId`，所以**补投路径是好的**；只有 `:633` / `:662`
这两条实时订阅路径是断的。这解释了「打开单聊页有时能看到、实时到达时看不到」。

`git log -p -- lib/peer/services/peer_agent_ids.dart` 显示 `392148e1` 同时删掉了：

```dart
String legacyPeerAgentLocalId(String peerId, String remoteAgentId) =>
    'peeragent_${peerId}_$remoteAgentId';
// 以及 decidePeerAgentRowId()：优先保留已存在的 legacy peeragent_* 行
```

存量数据没有跟着迁移，于是新代码对老行恒不匹配。

## 根因 B：卡帧没有会话归属（结构性）

即使修好根因 A，只要单聊页没打开（或卡晚于 `agent_done` 到达），孤儿卡仍会被
**任何**挂载着的群 Controller 认领 —— 因为事件里只有 `peer_id` +
`remote_agent_id`，没有任何「这张卡属于哪个会话」的信息，群分支无法判断它是不是
本群的卡。主机侧群回合反而有带 `channel_id` 的事件（CLI 侧调查结论：
`turn_exec.rs` 的 `interaction.pending`，行号未逐行核对），单聊审批这条路径没有。

## 决策

**审核 / 表单卡的归属由「发起回合的会话」决定，不由「哪个 Controller 恰好认领」
决定。** 与第 1 轮同源的裁定：不保留任何「退回当前 channel」的兜底。

### L1 止血（App 单侧，先修 id 口径）

让 DM 过滤与 `_drainPendingOrphanForms` 用同一口径，覆盖两种行 id 形态：

- 改 `lib/peer/services/peer_agent_ids.dart`：新增一个覆盖两种形态的判断
  （`agentId == remoteAgentId` 或 `agentId == 'peeragent_${peerId}_$remoteAgentId'`），
  `peerAgentLocalId` 保持语义不变或改名，二选一但别留下两个含义不同的同名函数。
- `lib/controllers/chat_controller.dart:633`、`:662` 换成新判断。

> 只做 L1 的副作用：单聊和群**都会**收到这张卡（双份）。所以 L1 不能单独交付，
> 必须紧接 L2。

### L2 根治（跨端，卡帧带会话归属）

#### 前置事实（调查后校正）

- **主机其实一直拿得到归属**：发给主机的 `session_id` 就是本端会话标识 ——
  `hostSessionIdForChannel()`（`peer_agent_client_service.dart:111-113`）：
  「`psess_` 壳剥掉，本机新建的 `dm_` 原样带上」。即普通单聊（`dm_<agent>_<user>`）
  发给主机的 `session_id` **就是 App 的 channel_id 本身**；`psess_` 同步会话发的
  是主机自己的 session id，而 `channel_id = psess_<它>`，映射是确定的。
  两套命名空间不同，但有确定映射，**不存在「拿不到」**。
- 主机侧 `start_agent_chat`（`crates/api/src/agent.rs:1821`，取参 `:1835-1885`）
  读到了 `session_id`，但只拿它做「历史隔离 / 会话 resume」的会话键
  （拼成 `agent:{agent_id}:{session}`），**没有往卡片帧里写** —— 归属信息在
  主机手里被丢在了最后一跳。
- 因此 L2 **不需要改 App 的发送路径**，只在主机侧把「收到的 `session_id` 原值」
  写进卡帧即可。（早先转述的「App 主路径漏发 channel_id 必须先补」是错的，
  已作废。）
- 群聊已经用带 `channel_id` 的事件流做归属：`interaction.pending`
  （`turn_exec.rs:260 / 369 / 426 / 475`、`dispatch.rs:380`，经
  `append_and_broadcast` 写 EventLog 广播）。单聊审批帧就是这个机制的缺环。
- **不能在 api 层给帧补字段**：`stdio.rs:2526` 先把帧 `clone` 进 `ApprovalBus`
  再 `on_frame`，断线补发 / 孤儿重放用的正是这份留底；补在 api 侧会导致重放的
  卡仍然没有归属。字段必须在 `stdio.rs` 出帧时就带上。

#### 改动（主机侧，App 未发布，不留兼容分支）

1. `crates/api/src/agent.rs:1885` 后：把已读到的 `session_id`（即 App 的会话标识，
   原值、未拼 session_key 的那个）往下带；`:2033` `active.begin(...)` 加实参。
2. `crates/api/src/active_turns.rs:29-34`：`TurnRef` 加 `channel_id`（同步
   `Debug` / `PartialEq`），`begin` 加参。
3. `crates/api/src/engine_ask.rs:86`：`agent_form_req` 加 `"channel_id"`
   （延迟帧 `:150-158` 同步）。
4. `crates/engines/src/stdio.rs`：`Turn` 加字段（`:40-49`）；`SessionPool::prompt`
   （`:501`）→ `AcpSession::prompt`（`:1277`）→ `Turn {}`（`:1291`）逐级传；
   超时重问处 `:1395` 透传；出帧 `:2515` 加字段。
5. 生产 caller 补参：`agent.rs:2049`（单聊，传**收到的 `session_id` 原值**，
   不要传 `agent:{...}:{...}` 那种拼过的 session_key）、
   `agent.rs:2441`（群，传 `group_id`）、`node_runtime.rs:244`。
6. 测试机械补 `""`：约 48 处（`stdio.rs` 42 处 `pool.prompt`、`agent.rs` 2、
   `engine_ask.rs` 4、`active_turns.rs` 6）。

> **取舍点（待裁定）**：显式传参（约 55 处机械改动，调用链清晰）vs 仿
> `QUEUED_MODEL`（`stdio.rs:17-25`）用线程局部量 + `pool.queue_channel_id()`
> （约 5 处，但隐式，且依赖 `queue_model`→`prompt` 同线程的既有先例）。

#### App 侧按会话认领

比对口径（一行搞定两种频道形态）：

```dart
// 帧里的 channel_id 就是当初发给主机的那个 session_id；当前频道换算回同一口径再比。
hostSessionIdForChannel(currentChannelId) == event['channel_id']
```

- 群分支（`:618-630` / `:646-658`）：只认领 `channel_id` 命中本群的卡；不匹配就
  **不碰 `messages`**，改走全局 `PendingApprovalHub` + 顶部横幅（与第 1 轮 L2 同构）。
- DM 分支（`:633` / `:662`）：同样按会话匹配，不再只比 agent 身份。
- 无归属的卡（`channel_id` 缺失）：按第 1 轮裁定，**不塞进当前会话**，走
  全局 hub；同时补一条告警日志便于下次定位。
- 孤儿事件构造处同步带字段（`peer_agent_client_service.dart` 的孤儿审批 /
  孤儿表单事件，约 `:7254-7262` 与 form 对应处）。

### L3 数据（需裁定）

存量 `peeragent_<peer>_<remote>` 行是否迁移到新 id。App 未发布，但本机库是真实
存量。倾向：**不迁移数据，L1 兼容两种形态** —— 迁移要动主键和所有外键
（channels 的 `dm_<agentId>_...`、channel_members、消息 sender_id），风险不划算。

## 实施步骤（分轮提交）

1. **第 1 轮（L1）**：`peer_agent_ids.dart` + `chat_controller.dart:633`/`:662`。
   补单测：两种行 id 形态都能被 DM 认领。 **已完成**，见下。
2. **第 2 轮（L2 主机）**：`stdio.rs:2515`、`engine_ask.rs:86` 补 `channel_id` /
   `session_id`；`cargo test -p shepaw-cli -p shepaw-api` 通过并补测试。
   **已完成**，见下。
3. **第 3 轮（L2 App）**：群 / DM 分支按会话认领 + 无归属走 hub。补单测：
   单聊卡不再落进群频道。 **已完成**，见下。
4. **第 4 轮**：真机冒烟（见下）。

## 第 1 轮实施结果

- 新增 `isPeerAgentRowId(rowId, peerId, remoteAgentId)`
  （`lib/peer/services/peer_agent_ids.dart`）：同时认 Hub id 与
  `peeragent_<peer>_<remote>` 两种行 id。`peerAgentLocalId` 语义不变，仍是
  「新行落库用的 id」，不要拿它做匹配。
- `chat_controller.dart:633` / `:662` 换用新判断。
- `test/peer/peer_agent_row_id_test.dart` 补 4 例（Hub id / legacy 前缀 /
  别的 peer / null），连同原有共 8 例全绿。该测试原本 import
  `peer_agent_client_service.dart`，已改为直接 import `peer_agent_ids.dart`
  （它只用到 ids 里的函数，依赖面更小）。
- **未做**：L2（会话归属）。只做 L1 时单聊与群会各收一份卡，L2 必须紧接。
- 应用侧整包编译当时被另一处在途未提交改动阻塞
  （`peer_agent_client_service.dart:4418` 调用了尚未定义的
  `_mirrorHostSessionList`），与本轮无关，验证时先确认那处已补齐。

## 第 2 轮实施结果（主机侧 L2）

**实际做法与上面步骤的偏差：不新增 `TurnRef.channel_id`，改为在 `stdio.rs` 里
从 `session_key` 反推 `channel_id`。**

理由：`SessionPool::prompt(session_key, …)` 的 session_key 本身就编码了聊天身份 ——
单聊是 App 发来的 `session_id` 原值（可能是 `dm_<agent>_<user>` 或主机自己的
session id），群聊是 `group:<group_id>:<session_id>[:…]`。在 `stdio.rs` 的出帧
点是唯一必须带字段的地方（`ApprovalBus` 存的就是这里的帧），从这里反推可以避免
给 `TurnRef` / `begin` / `agent.rs` / `node_runtime.rs` 及约 50 处测试调用点
机械补参，改动面小得多，也不会让两处（`TurnRef` 与 `session_key`）的归属有
不一致的可能。

- `crates/engines/src/stdio.rs`
  - 新增 `fn channel_id_for_session_key(&str) -> &str`：`"default"` → `""`
    （没有会话的旧请求对 App 就是无归属）；`group:<gid>:…` → `<gid>`；
    其余原样返回。
  - `Turn` 加 `channel_id: &'a str`；`SessionPool::prompt` 计算后经
    `AcpSession::prompt(..., channel_id)` 传入；`explain_timeout` 透传。
  - `ask_phone` 帧（`agent_approval_req`）写 `"channel_id": turn.channel_id`。
  - 辅助 `Turn {}` 字面量 7 处填空串。
- `crates/api/src/engine_ask.rs`：`agent_form_req` 与 `agent_form_deferred`
  从 `turn.session_id` 取 `channel_id`，`"default"` 置空。
- 新增/修改测试：
  `card_channel_id_follows_the_session_key`（单聊原值 / 群取 gid / default 空）、
  `permission_request_waits_for_the_phone` 断言帧里的 `channel_id`；
  `engine_ask` 两个测试断言表单帧与延迟帧的 `channel_id == "s-1"`。
- `cargo test -p shepaw-engines -p shepaw-api`：131 + 67 全绿。
- 未改 `TurnRef`，因此 `active_turns.rs` / `agent.rs` / `node_runtime.rs`
  无改动；文档「改动（主机侧）」第 1、2、5 条作废。

## 第 3 轮实施结果（App 侧 L2）

- `lib/peer/services/peer_agent_ids.dart`：新增
  `orphanCardBelongsToHostSession(frameChannelId, hostSessionId)`，帧归属为空或
  与当前会话不等时一律不认领（不保留「退回当前 channel」兜底）。
- `lib/peer/services/peer_agent_client_service.dart`
  - `_frameChannelId(data)` 读帧里的 `channel_id`；孤儿审批 / 孤儿表单事件都带上
    它，补投缓存里也保留。
  - `pendingOrphanFormsFor` 增加可选 `hostChannelId` 过滤；新增
    `pendingOrphanApprovalsFor({peerId, remoteAgentId, hostChannelId})`，按会话
    过滤并复用 `PeerApprovalPayload.buildActionConfirmationData` 构造卡片数据。
  - **无论当前打开的是哪个页面**，孤儿卡到达时先经 `_publishOrphanCardToHub`
    登记全局 `PendingApprovalHub` 提醒（表单与审批同属 `action` 类，id 分别用
    `form_id` / `confirmation_id`），保证横幅不漏。`_localChannelIdForCard`
    先按 `hostChannelId` 找本机频道，再试 `psess_<hostChannelId>`；都找不到时
    （例如旧主机的无归属帧）回退到该 agent 的普通单聊频道，避免完全无提醒。
  - GetIt 未注册 `LocalDatabaseService` 时（纯逻辑单测）直接跳过提醒，不影响收卡。
- `lib/controllers/chat_controller.dart`：孤儿监听入口统一先过
  `_claimsOrphanCard(event)`（按 `hostSessionIdForChannel(currentChannelId)` 比对
  帧 `channel_id`），群 / 单聊分支都不再只看 agent 身份；`_drainPendingOrphanCards`
  补投时同时传 `hostChannelId`。
- `lib/controllers/chat_controller_messaging.dart`：孤儿审批落消息行时用
  `peer_approval_<approvalId>` 作为确定性 id（重复补投 / 重开页面落到同一行，
  已有则跳过）；各分支剥离 `channel_id` 等传输字段，不写进消息。
- `lib/controllers/chat_controller_interactions.dart`：`_handleInteractionClosed`
  先 `resolveByConfirmationId` 清全局提醒（横幅可能指向别的会话，本页没有对应
  消息行）；peer 表单提交成功后同样清提醒。
- `lib/services/approval/pending_approval_item.dart`：`fromInteraction` 接受
  `form`，但**只有带 `form_id` 时**才生成提醒（否则事后无法消解，宁愿不提醒）。
- 测试：`test/peer/peer_orphan_approval_test.dart`（新）、
  `test/peer/peer_orphan_form_test.dart`（按会话过滤）、
  `test/peer/peer_agent_row_id_test.dart`（`orphanCardBelongsToHostSession`）、
  `test/services/approval/pending_approval_hub_test.dart`（表单提醒可按 id 消解）、
  `test/controllers/chat_orphan_card_routing_test.dart`（新，控制器入口）：
  - 群 Controller 收到单聊卡 / 无归属卡时不写 `messages`、不登记本群提醒；
  - 归属本群的卡照常渲染（证明监听确实装上，不是空跑）；
  - DM Controller 只认领本频道，别的会话的卡不落进来。
  为让纯逻辑测试能装监听而不跑 `init()` / 本地库加载，把订阅块抽成
  `_installOrphanCardListeners()`，并加 `@visibleForTesting`
  `installOrphanCardListenersForTest()`；生产路径仍由 `init()` 调用同一个方法。
- `flutter analyze --no-pub` 0 error；`flutter test test/peer test/controllers
  test/services/approval` 615 例全绿。

## 验证方法

- 日志 tag `PeerApproval`：
  - `agent_approval_req: no pending request for requestId=… buffering as orphan`
    → 确认走的是孤儿路径；
  - `group orphan peer approval: agent=… channel=group_…`
    → 确认被群认领（修好后单聊卡不应再出现这条）。
- 库里查落点（只读）：
  ```sql
  SELECT created_at, channel_id, sender_id, sender_name, substr(metadata,1,160)
  FROM messages
  WHERE metadata LIKE '%action_confirmation%' OR metadata LIKE '%"form"%'
  ORDER BY created_at DESC LIMIT 20;
  ```
  修好后：单聊回合产生的卡 `channel_id` 应是 `dm_…`，不再是 `group_…`。
- 回归：`flutter test` 相关子集与基线比对（基线全绿，见记忆
  「shepaw 回归比对方法」）；Rust 侧 `cargo test -p shepaw-cli -p shepaw-api`。
  本仓库**不要跑 `dart format`**。

## 注意事项

- 工作区有未提交改动（`crates/api/src/files.rs`、`crates/api/src/pouch.rs`、
  `crates/cli/src/mcp.rs` 等）。**不要覆盖或回滚**它们；`mcp.rs` 那处是 pouch URI
  归一化，与本轮无关。
- `docs/review/2026-10-17-ask-user-tool-review.md`（`ask_user` schema 评审）在
  并行进行中。本轮只往卡帧加归属字段，**不要顺手改 `questions` / `options` 的
  schema 或描述**。
- 群聊里 `ask_user` 是被主动关掉的（`stdio.rs:2400-2408`
  `should_enable_ask_mcp`：session_key 以 `group:` 开头或 request_id 以 `group-`
  开头就置 `SHEPAW_MCP_ASK_USER=0`）。所以群里出现的 `agent_form_req` 一定是
  从别处串过来的 —— 这条可以作为回归断言。

## 第 4 轮：同一 agent 多 DM 会话并发（2026-11-11）

L2 只把归属加在了**首张卡帧**上，后续链路仍是「全局 `approval_id` + 可选
`channel_id`」。实测（hub.log 卡 `ead6ac66`：14:45Z 建、14:50Z deferred、
14:51Z 已答、22:48Z 又被另一台设备答一次且 `resolved=false`）与 App 日志的
`buffering as orphan form` 都说明：**孤儿 / 补发 / 历史残留卡仍能在任意打开
的会话里被点选提交**，多 DM 并发时就会「在 A 会话回答 B 会话的问题卡片」。

### 与第 3 轮裁定的偏差

本文件 `:169` 写的是「无归属的卡不塞进当前会话，走全局 hub」；实现却在
`chat_controller.dart` 的 `_claimsOrphanCard` 里让**任何打开的 DM** 认领无归属
卡，`_drainPendingOrphanCards` / `_replayOpenInteractions` 还都传了
`includeUnattributed: true`。单会话时碰巧对，多会话时同一张卡会被灌进所有
打开的 DM。回归用例 `chat_orphan_card_routing_test.dart` 当时只在**群**
Controller 上测了「没有归属不认领」，DM 分支漏测。

### 本轮改动

主机（`shepaw-cli`）：

- `agent_form_resp` 新增可选 `channel_id`；主机用 `ApprovalBus::channel_for`
  比对卡片归属，不一致就记日志并静默丢掉答案（不回 `agent_error`，免得把
  答案所在回合判成失败），也不消费等待位。老客户端不带该字段时跳过校验。
- `agent_interaction_closed`（`engine_ask` / `stdio` / deferred 收场）、
  deferred payload 全部带上 `channel_id`，主机重启后仍能按归属收场。

App：

- 删除「无归属卡由当前 DM 认领」兜底：`_claimsOrphanCard`、
  `_showPeerFormCard` 与四处 `includeUnattributed: true` 一律收紧。无归属卡
  仍由 `_publishOrphanCardToHub` 落到固定单聊 + 全局横幅，用户从横幅跳过去。
- 卡片落库时写 `card_channel_id`（主机会话 id 口径）；`dockedPendingInteraction`
  按当前会话过滤停靠卡；`handleFormSubmitted` 在提交前校验归属；`submitForm`
  把 `hostSessionIdForChannel(currentChannelId)` 放进回包。
- `_onFormReq` 以帧里的 `channel_id` 为权威（不再只信 pending 的频道快照），
  `_isPersistedOpenForm` 拒绝别的频道里残留的同 id 卡。

回归用例：两个同时挂载的同 agent DM Controller + 无归属卡 → 两边都不写
`messages`；归属 B 的表单卡只进 B；A 会话提交 B 的卡被拦下；dock 不显示
别的会话的卡（`psess_` 壳按同一口径换算）。

## 第 5 轮：卡片有效性检测 + 工具审批卡 / submitForm 回执（2026-11-11）

裁定（用户确认）：打开会话若有答题卡片**立即**查一次；还有效的每 **15 秒**复查；
被其他端回答的卡**保留并标成已答 + 提示**；确认失效的直接移除；离开当前会话
停止检测；检测范围覆盖所有交互卡。

主机：

- `agent_approval_resp` 加可选 `channel_id`，和表单卡一样做会话校验；
  `agent_card_resp_ack {approval_id, ok, reason}` 让 `submitForm` /
  `submitApproval` 不再把「帧写进 socket」当成功（老主机无 ack 时 App 3 秒
  超时退回原行为）。
- `agent_card_status_req {request_id, channel_id, card_ids, interaction_ids}`
  → `agent_card_status_resp {cards:[{id,state}]}`，state ∈ `alive` /
  `answered_elsewhere` / `answered_here` / `closed` / `gone`。
- `ApprovalBus` 增加 30 分钟 / 256 条的短时关闭账本（记录 reason 与作答设备），
  `PhoneState` 给旧式 `interaction_id` 卡同样记一笔；状态查询据此区分
  「别的设备答了」和「卡早就不存在」，并按 `channel_id` 排除别的会话的卡。

App：

- `_controlTypes` 收 `agent_card_status_resp` / `agent_card_resp_ack`；
  `PeerAgentClientService.checkCardStatus` 按 request_id 等回包，超时返回空
  列表（**网络抖动绝不删卡**）；`submitForm` / `submitApproval` 等 ack，
  `ok=false` 抛 `PeerCardRejectedException` 且按 reason 收卡，不标已答。
- 工具审批卡落库写 `card_channel_id`（表单卡同款）；`handleActionSelected`
  提交前校验归属；`submitApproval` 从落库归属补 `channel_id`，不必逐层透传。
- `ChatController` 新增卡片有效性轮询：`loadMessages` 结束立即查一次 +
  `Timer.periodic(15s)`；`switchChannel` / `dispose` cancel；异步回来用
  `currentChannelId` 代际守卫。`gone` 删行（DB + 内存），`answered_elsewhere`
  写 `closed` 让 `InteractionClosedHint` 渲染「已在别处作答」并弹提示，
  `alive` 不动。定时器跟着会话走（无卡时只跳过请求），保证期间新到的卡
  下一轮仍会被检测。
- hub 卡只在 `interaction_ids` 里查（`hub_interaction` 与 `metadata[kind]`
  同存一份，按 approval_id 查会被主机回 `gone` 而误删）；CLI 卡无主机等待位，
  单选/多选/文件上传是本地工具卡，都不参与对账。

## 第 6 轮：提交后复审返修（2026-11-11）

提交 `ff8d111`（主机）/ `00e7baba`（App）之后做了 8 角度复审，逐条核验并返修：

- **早退分支绕过密封**：`Router::dispatch` 的 `match` 里 `return HandlerReply::Frames(...)`
  会跳过末尾的 `seal_reply`，ack 以明文发出。把整个 match 包进闭包，`return`
  只从闭包返回，所有回包统一密封；两端的回执测试改为拆封后断言。
- **工作节点卡被误判失效**：`agent_card_status_req` 原来只查本机 `ApprovalBus`，
  工作节点转来的卡在 `relay::pending_frames_for` 里，会回 `gone` 让 App 删掉
  还活着的卡。补上 relay 白名单，命中即回 `alive`。
- **转发路径没有回执**：`relay::approval` 成功后原来直接 Quiet，App 要白等 3 秒。
  现在回 `ok: true, reason: forwarded`。
- **取消被记成「别处已答」**：`resolve(id, peer, "")` 是停止信号，账本改记
  `cancelled`；`close_ids` 的口径保持一致。
- **会话归属两处口径漂移**：`engine_ask` 改用 `stdio` 导出的
  `channel_id_for_session_key`（`group:` / `flow:` / `default` 统一归一化）；
  flow 的 deferred payload 与 `publish_card_closed` 补上 `channel_id`。
- **旧式 interaction 卡无归属**：卡帧补 `channel_id`，`InteractionWaiter` 记住它，
  状态查询按会话排除；关闭账本加 30 分钟 TTL、按时间淘汰最旧、记录作答设备，
  本设备自己答的回 `answered_here`，不再弹「已在其他设备回答」。
- **App 生命周期**：`dispose` 之后在途状态回包仍会改写已销毁 controller
  （`currentChannelId` 不变，频道守卫挡不住），补 `_cardValidityDisposed` 显式标志；
  `loadMessages` 一轮里会多次调用，加 2 秒同频道节流（切频道立即重查）；
  `hostChannelIdForCard` 命中多条不同归属的行时不猜、不带 `channel_id`。

### 仍未覆盖

- `flow:` session_key 的审批卡 `channel_id` 本来就是空（stdio 的既有口径），
  这类卡不做会话校验。
- `take_deferred()` 的 hub 内部路径记不到作答设备，工作流 gate 卡由本端答掉时
  轮询仍可能回 `answered_elsewhere`（只是多一条提示，卡片状态正确）。
- 广播 / 补发仍是设备级 fan-out，没有按会话准入；完全的根治需要客户端在
  `agent_pending_interactions_req` / 事件补拉里声明会话。
- `CardStatus` 账本只在进程内，主机重启后旧卡一律判 `gone`（那时旧卡确实
  也不该再答）。

## 第 7 轮：跨端复审返修（2026-11-11）

第 6 轮提交后再做一轮（主机 Rust 8 角度 + App 10 角度，逐条核验前提后返修）。
本轮的核心结论：**第 5 轮的「15 秒卡片有效性轮询」会把还活着的卡删掉**，
而且有几条提交路径绕过会话校验。返修按「误删活卡」「串会话漏网」「回执时序」
三组落地。

### 误删活卡（高危）

- **旧式 hub 卡归属口径错**：`ask_ui_for_agent` 的卡帧 `channel_id` 取自
  `frame.session_id`，群回合是群会话 id（`s_x`），而 `interaction.pending`
  事件按群频道 id（`group_g1`）广播，App 也按 `group_g1` 查状态 → 主机判
  `gone`、App 删掉活卡。主机新增 `card_channel_id(frame)`：优先
  `frame["channel_id"]`，为空才回退 `session_id`，并剥 `psess_` 壳、把
  `default` 归一为空。
- **本地工具卡被当成主机卡对账**：App 的 `checkCardValidity` 原来把所有
  `metadata['form']`（`form_id`）和非 cli 的 `action_confirmation` 都塞进
  `card_ids`；本地 She / 群编排 / CLI 卡也带这些 id，但主机没有等待位，一律
  回 `gone`，打开页面几秒卡就被删。现在只收**明确带主机标识**的卡：
  `hub_interaction`（→ `interaction_ids`）、带 `peer_form` 的表单卡、带
  `card_channel_id` 的 peer 审批卡。
- **所有卡塞给一台主机**：原来取第一张卡的 peer，或退化为
  `connectedPeerIds.first`；群聊里两台主机的卡会被问到对方主机上，全部回
  `gone` 删掉。改为按 `host_peer_id` / `peer_form.peer_id` / `card_peer_id`
  分组，每台主机只收到自己的卡；无归属的卡只走本会话 agent 的主机，且仅在
  **只有一台已连接主机**时才用兜底，绝不乱猜。
- **别的会话残留卡被对账**：采集时先看消息顶层的 `card_channel_id`，非空且
  不等于本次查询的 channel 就跳过——否则拿 A 的归属问主机，删掉的是 B 会话
  里唯一一份落库副本。
- **relay 白名单不按会话过滤**：`worker_cards` 原来只按 approval_id 命中就改判
  `alive`，别的会话残留的 `gone` 卡被一直保活。改成 id → channel_id 映射，
  归属不匹配就保持 `gone`。

### 串会话漏网

- **relay 转发绕过校验**：`agent_form_resp` / `agent_approval_resp` 在本地
  校验之前就调 `relay::approval` 转发并回 `ok=true, forwarded`。新增
  `relay::approval_channel(id)`，留底帧带归属且提交帧归属不一致时回
  `session_mismatch`，不消费等待位。
- **`pouch_interaction_resp` 协议没有归属**：`frames.rs` 加可选
  `channel_id`（老客户端缺省跳过校验），主机 `complete_interaction_by` 前比对
  `PhoneState::interaction_status`；App 三处发送端（`_answerHubInteraction`、
  `pouch_turn_relay`、`hub_event_client`）都带上会话，relay 那条再做一次
  `psess_` / `default` 归一。
- **关闭账本没记归属**：`ClosedCard` / `ClosedInteraction` 只记 reason / 设备 /
  时刻，B 会话答掉的卡在 A 会话轮询会命中账本回 `answered_elsewhere`，把
  错会话的残留卡永久留在屏幕上。两本账本都补 `channel_id`，命中且不匹配就
  归 `gone`。
- **审批卡归属在孤儿 / 补投路径被剥掉**：Controller 三处把 `channel_id` /
  `peer_id` remove 后才交给 `_handleStreamingActionConfirmation`，于是
  `card_channel_id` 永远写不出来，`submitApproval` 也没法带归属。改为
  `_orphanApprovalCardData` 把两者转成消息顶层的 `card_channel_id` /
  `card_peer_id`；`submitApproval` 接受作答时所在会话（不能只信卡片自己的
  DB 归属，那等于让卡自证），`declineForm` 与两处自动重放也补上 `channel_id`。
- **无归属孤儿审批卡无处作答**：`_publishOrphanCardToHub` 原来只给表单卡落
  确定性消息行；收紧「无归属卡不由任意 DM 认领」之后，这类审批卡横幅点开
  是空会话。现在也落 `peer_approval_<id>` 行（带 `card_peer_id`）。
- **`hostChannelIdForCard` 的 LIKE 未转义**：`approval_id` 常含 `_`，SQLite
  LIKE 会把它当通配符捞到无关行，假歧义导致返回空、主机跳过校验。改为先按
  两个确定性消息 id 精确查，退回子串扫描时转义 `%` / `_` / `\` 并复核卡里的
  id 与 approvalId 完全相同。
- **`_onFormReq` 帧归属与回合频道不一致时仍按回合频道落库**：确定性 id 只有
  一条，写进 A 后 B 永远加载不到，A 的轮询又会把这张活卡判 `gone` 删掉。
  新增 `_persistFormCardForFrame`，不一致时按帧归属解析本机频道再落库。

### 回执时序 / 生命周期

- **3 秒回执计时从发送前开始**：`_awaitCardRespAck` 在重连发送循环（单次
  最长 6 秒）之前就启动超时，主机 `ok=false` 到达时等待位已被摘掉，App 当成
  「老主机」把卡标成已答。拆成发送前 `_registerCardRespAck` 登记、帧确实
  发出后才 `awaitCardRespAck` 计时。
- **等待位按 approval_id 单键覆盖**：双击 / 快速重试会互相清掉等待位。改成
  一组等待位，回执到达时一起完成，各自 `finally` 只摘自己；另加 30 秒终态
  回执账本，覆盖「第二次提交在第一个 ack 之后才登记等待位」的时序。
- **终态拒收被通用 catch 回滚**：`PeerCardRejectedException(expired /
  answered_elsewhere)` 不匹配 `PeerApprovalExpiredException.matches`，
  `interactive_response_handler` 把它当瞬时失败回滚，把已失效卡恢复成可点；
  `resubmitLostFormAnswer` 也会 reopen。给异常加 `isTerminal`，两处都按终态
  处理。
- **`declineForm` 不等 ack 就清账簿收卡**：主机在「答案没接住、卡片保留」
  时仍保留等待位，App 却已把卡关死。现在等回执，`ok=false` 时不动本地状态。
- **`_showPeerFormCard` 整份覆盖 metadata**：重复补投时用内存气泡的 metadata
  全量回写 DB，抹掉服务层刚写的 `card_channel_id`。改用 `mergeMessageMetadata`
  只 patch 卡片字段；`_markCardAnswered` 同样改为 patch。
- **切频道 / dispose 期间在途回包仍改状态**：原来只在 `_applyCardStatus`
  入口查一次。加 `_cardValidityGeneration`（stop / dispose 递增），每个 await
  之后和每次 mutation 之前复核；`stopCardValidityWatch` 同时清在途标志，让
  新会话能立即查。
- **每次 `loadMessages` 重建 15 秒定时器**：活跃回合里倒计时不断被清零，
  轮询永不触发。改成只在定时器未 active 时创建。
- **note-only 用例断言恒真**：外层是 `pouch_sealed`，`frames.iter().any(...)` 永远
  为 false。改为先拆封再断言「无 agent_error + 有 answer_pending ack」。

### 验证

- 主机：`cargo test -p shepaw-gate -p shepaw-api -p shepaw-engines
  -p shepaw-protocol --offline` → 614 / 106 / 31 / 14 全绿（+5 个新用例）。
- App：`flutter analyze` 0 error；卡片相关 6 个测试文件全绿（含 7 个新增
  回归用例：本地卡不删、错会话卡跳过、按主机分组、定时器不重建、切频道
  代际守卫、并发回执、终态异常匹配）；全量 3950 例只剩 4 个失败
  （`flow_field_catalog` / `group_context_builder` / `flow_workspace_screen`
  两个 Timer 待处理），在干净 main 上单跑同样 4 个失败，确认与本次改动无关。

### 仍未覆盖（本轮新增）

- 老帧完全没有 `channel_id` 时主机回退到 `session_id`，若那是 `group:` /
  `flow:` 主机键，仍与 App 频道口径不一致；需要保证所有旧式卡帧都带
  `channel_id`。
- relay 的会话校验查的是进程级全局表，若本机卡与残留 relay 记录恰好同 id
  会误拒（id 是 UUID / 确定性 flow id，概率极低）。
- `PouchInteractionResp.channel_id` 是两阶段上线的可选字段：老主机忽略，
  老 App 不发；只有两端都升到本轮之后，旧式 hub 卡的跨会话拦截才生效。
- `flow:` 审批卡、hub 内部 `take_deferred` 记不到作答设备、广播仍是设备级
  fan-out、`CardStatus` 账本只在进程内——沿用第 6 轮的既有缺口。

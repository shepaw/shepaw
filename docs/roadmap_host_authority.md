# 主机权威化路线图（合并版）

状态：进行中。这份是总纲，细节在三个子文档里，冲突时以本文件为准。
子文档：`acp_network_switch_resilience_decision.md`（切网可靠性）、`mailbox_retirement_decision.md`（mailbox 下线）、`session_history_authority_decision.md`（ACP→peer 迁移）。

## 目标架构（一句话）

**主机（Rust `shepaw-cli`）持有会话与消息，App 只负责连上去拉数据渲染。** 没有第二方主机，没有第三方中转存留。

## 四条决定一切的事实

1. **主机只有 `shepaw-cli`（Rust）**，agent-bridge（TS）已废弃，残留进程已清（2026-10-13）。
2. **主机只有一个 WS 端点 `/peer/ws`**。直连白名单（`crates/peer/src/server.rs:450`）和 Channel 隧道（`crates/peer/src/tunnel.rs:359`）都只放行 `/peer/ws`。**`/acp/ws` 连不上 Rust 主机** —— 直连不行，隧道也不行。
3. **peer 路径已经是目标架构**：transcript 按游标增量拉、断连挂起等重连、`agent_turn_resume_req` 断点续传、主机侧按会话排队（busy 不再出现）。Agent 靠配对后 `agent_list_req` 自动发现建行。
4. **`ProtocolType.acp` 是死路径**。它的服务方就是 agent-bridge；进程清掉后，acp 行的 `/acp/ws` endpoint 全是死地址。剩下的 acp 行要么连不上，要么只是 tag 碰巧是 acp（protocol 字段默认值、惜宝的本地行）。

## 已完成

| 轮次 | 提交 | 内容 |
| --- | --- | --- |
| 切网 1 | `ce3bb498` | 建连 15s 超时、`disconnect` 先解封再关且最多 2s、等落库 30s 兜底、回合超时 3h→30min |
| 切网 2 | `4abdc221` | 掉线进 20s 重连窗口 + 重连后续传、切网 ping 体检半开连接、resume 禁重入 |
| 切网 3 | `afb6652d` | 补拉连续失败 2 次才判死 |
| mailbox A | `35768a33` | 拆投信侧：主机不可达/正忙直接落系统消息，不再往 Channel 投信 |
| 惜宝 (a) | `2e218491` | 删掉本机惜宝空壳行，惜宝只由 Hub 提供 |
| ACP R1+R2 | `25741e45` | DM 不再走 ACP；删 `_sendViaACPProtocol`、停滞看门狗、切网体检 |

> 前三轮切网改造都做在 ACP 路径上。ACP 退役时它们会一起删掉 —— 但**不是白做**：核查确认 peer 侧这些能力本来就齐（建连 10s、断连挂起、无限退避重连、续传幂等、应答看门狗），所以在退役完成前的中间态里用户是受益的，且这份核查本身就是退役的前提。

## 剩下的活（按依赖顺序）

### 1. 退役 ACP 路径（前置：下面的待定问题）

**爆炸半径（已量）**：22 个文件引用 `ACPAgentConnection`，核心文件 `acp_agent_connection.dart` 1867 行。拆成四小轮，按依赖推进：

- **R1 断路** ✅（`25741e45`）：发送入口对 `ProtocolType.acp` 不再建连接，直接落「这个 Agent 已不可用，请改用 Hub 配对后添加」。
- **R2 删发送实现** ✅（`25741e45`）：`_sendViaACPProtocol`（574 行）、`_getOrCreateACPConnectionWithRetry`、停滞看门狗、切网体检。前三轮切网改造至此全部退役。
  - 惜宝的挡路点也一并解决（`2e218491`）。
  - 群聊不受影响：`GroupAgentExecutor` 里的 `getOrCreateACPConnection` 只有字段声明、从未被调用过。
- **R3 删连接本体**：`acp_agent_connection.dart`、`acp_protocol_handler.dart`、`acp_interactive_connection.dart` 适配、`ProtocolRouter`（它现在对 peer 直接抛异常，是 ACP 专用）。
- **R4 收尾**：`ProtocolType.acp` 枚举值、`acpTaskTimeout` 的引用（`group_member_stall.dart`、`chat_service.dart:1410`）、widget 里的 acp 判空、`slash_command_picker`、`ws_file_transfer_service`。

#### ⚠️ R1 之前必须先解决：惜宝

`she_service.dart:208` 把本地惜宝行建成 `ProtocolType.acp`，且 `endpoint: ''`、无 `llm_provider`（所以 `isLocal` 为 false、`relaysHostSheTurn` 也要求 `isPeerAgent` 才成立）。

**结论：本地惜宝行会落进 ACP 分支，而空 endpoint 必然连不上 —— 它现在就是坏的。** 一旦 R1 把 acp 判为不可用，必须同时决定它的去处：

- (a) **删掉本地惜宝行，惜宝只由 Hub 提供**（peer 行）。与新架构一致，代码最干净；本地行只是首次创建时的兜底（`she_service.dart:158-178`，已有 peer 行时不会建）。
- (b) 保留本地行但给它一条明确的本地路径（等于把本机 LLM 那套接上）。
- (c) 保留并标为不可用（最省事，但用户会看到一个点不动的惜宝）。

我倾向 (a)：新架构下惜宝本来就该是主机上的 agent。但这会动到用户可见的内置角色，需要你点头。

### 2. 下掉每轮打包 history

`_sendViaACPProtocol` 的 `chatHistory` / `totalMessageCount`。peer 侧 history 本来就是可选参数（`peer_agent_client_service.dart:2460`），主机有自己的 transcript。顺带 `history_compactor`、`totalMessageCount` 记账一起退。

### 3. mailbox 收信侧删除（依赖 1）

`fetchMailboxReplies` 与四层去重、进页补拉、回前台 `drainAllMailboxReplies`、WS 推送订阅。ACP 退役后没有消费方。

### 4. 清场（依赖 3）

删 `lib/services/mailbox/`（含仍在用的 `mailbox_seal`）、`group_mailbox_save_plan.dart` 及相关测试。库里已有消息的 `from_mailbox` / `mailbox_entry_id` 保留不洗。
另跨仓库清 `shepaw/channel` 的 mailbox 表与路由。

## 待定问题

### 已解决（2026-10-13）：有没有「非 Hub 来源」的 agent？

**没有第三方自建 ACP 服务** —— 已确认。所以 ACP 路径整体退役，按上面 1→4 一次推完，不需要并行期。

### 待定：本地惜宝行怎么处置（挡住第 1 步的 R1）

见上一节 ⚠️。三个选项里我倾向 (a) 删掉本地行、惜宝只由 Hub 提供，但它是用户可见的内置角色，需要你点头。

## 风险

- **退役 ACP 会删掉刚做的可靠性改造**。peer 侧能力已核查齐备，但两边实现不同（peer 是无限重连 + 挂起 25h，ACP 是 20s 宽限），统一后行为会变，值得真机再验一次切网。
- **peer 路径依赖已配对 Hub**，没有「填 URL 直连」的入口。如果确实存在直连场景，peer 覆盖不到。
- 第 3、4 步之间有个中间态：收信代码还在但没人往里投了，纯死代码，别拖太久。

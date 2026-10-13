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

> 前三轮切网改造都做在 ACP 路径上。ACP 退役时它们会一起删掉 —— 但**不是白做**：核查确认 peer 侧这些能力本来就齐（建连 10s、断连挂起、无限退避重连、续传幂等、应答看门狗），所以在退役完成前的中间态里用户是受益的，且这份核查本身就是退役的前提。

## 剩下的活（按依赖顺序）

### 1. 退役 ACP 路径（前置：下面的待定问题）

删 `ACPAgentConnection` 及 JSON-RPC 方法表、`ProtocolType.acp` 分支、`acpConnectTimeout` / `acpDmTaskTimeout`、前三轮切网改造里只为 ACP 写的部分。
注意 `group_member_stall.dart`、`chat_service.dart:1410` 引用了 `acpTaskTimeout`，要一并处理。

### 2. 下掉每轮打包 history

`_sendViaACPProtocol` 的 `chatHistory` / `totalMessageCount`。peer 侧 history 本来就是可选参数（`peer_agent_client_service.dart:2460`），主机有自己的 transcript。顺带 `history_compactor`、`totalMessageCount` 记账一起退。

### 3. mailbox 收信侧删除（依赖 1）

`fetchMailboxReplies` 与四层去重、进页补拉、回前台 `drainAllMailboxReplies`、WS 推送订阅。ACP 退役后没有消费方。

### 4. 清场（依赖 3）

删 `lib/services/mailbox/`（含仍在用的 `mailbox_seal`）、`group_mailbox_save_plan.dart` 及相关测试。库里已有消息的 `from_mailbox` / `mailbox_entry_id` 保留不洗。
另跨仓库清 `shepaw/channel` 的 mailbox 表与路由。

## 一个待定问题（决定第 1 步能不能一次做完）

**现在还有没有「非 Hub 来源」的 agent？** 也就是第三方自建 ACP 服务、或直连某台主机而不走配对。

- **没有** → 按上面 1→4 一次性推完。
- **有** → ACP 路径要保留，第 1 步拆成「并行一段时间再退」，前三轮切网改造继续有效，mailbox 的投信替代方案也要重新考虑（第三方场景下主机不可达是常态，没有中转就发不出去）。

我的判断是「没有」：agent-bridge 是唯一已知的 `/acp/ws` 服务方，已经废弃，残留进程也清了；主机侧除了 `/peer/ws` 没有任何对外入口。但需要你确认，因为这事关要不要保留一整条路径。

## 风险

- **退役 ACP 会删掉刚做的可靠性改造**。peer 侧能力已核查齐备，但两边实现不同（peer 是无限重连 + 挂起 25h，ACP 是 20s 宽限），统一后行为会变，值得真机再验一次切网。
- **peer 路径依赖已配对 Hub**，没有「填 URL 直连」的入口。如果确实存在直连场景，peer 覆盖不到。
- 第 3、4 步之间有个中间态：收信代码还在但没人往里投了，纯死代码，别拖太久。

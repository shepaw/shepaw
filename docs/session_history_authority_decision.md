# 轮 B：消息权威迁到主机（前提修正 + 待裁定）

状态：**卡在一个前提问题上，需要你定**
范围：App（`shepaw/lib`）+ 视裁定可能要动 `shepaw-cli` 或 `agent-bridge`

## 先纠正我之前写错的一句话

我在 `docs/mailbox_retirement_decision.md` 里写过：「`agent_session_history_req` 现在只挂在 hub/peer 的帧路由上，ACP 那条 WS 上没有，要把它挂过去。」

**这句是错的。** 挖下去发现事情不是这样，先把真实地形摆出来。

## 真实地形

### 主机侧只有一个 WS 服务端点

`shepaw-cli` 全仓只有一个 WebSocket server：`crates/peer/src/server.rs:87 serve()`，路径白名单硬编码只认 `/peer/ws`（`server.rs:450`，`OnlyPeerPath`）。没有第二处 `accept_hdr_async`。

帧格式是 `#[serde(tag = "type")]`（`crates/protocol/src/frames.rs:38`），**不是** JSON-RPC `method`。全仓 `"method"` 只出现在 `crates/engines/src/stdio.rs` —— 那是主机跟引擎子进程（Claude/Codex）之间说的业界 ACP，和 App 那套不是一回事（`protocol/src/lib.rs:2-7` 明确写了两套 ACP 不要混用）。

`agent_session_history_req` 就在 `crates/api/src/lib.rs:986`，和 `AgentChat` 等帧在**同一个 `match`** 里。也就是说：凡是连到 `/peer/ws` 的客户端，本来就能拉历史。

### 主机已经持有 ACP 回合的 transcript

`session_history()`（`crates/api/src/agent.rs:856`）有四支，其中 `Located::Shepaw`（`:902`）读 `AgentSessionStore`。而 ACP 回合的用户消息和助手消息正是写进 `AgentSessionStore` 的（`agent.rs:1411` 与 `:1498` 两处 `sessions.append`）。

游标分页也是现成的：`v1.<count>.<hash>`（`crates/api/src/history_cursor.rs:84-88`），按前 `stable` 条做链式指纹，`total < count` 或哈希不符就 `reset: true` 让客户端从头拉；相邻页重叠一条便于拼接；单页 1MB 上限、缺省 limit 200、上限 500。

**结论：主机侧对「持 transcript + 按游标分页」这件事，能力是齐的，而且早就齐了。**

### App 有两条互不相同的协议路径

| | `ProtocolType.peer` | `ProtocolType.acp` |
| --- | --- | --- |
| 连到 | `/peer/ws` | `/acp/ws` |
| 帧格式 | `type` 标签 | JSON-RPC `method`（`agent.chat` / `agent.taskResume` / `ping`，见 `lib/models/acp_protocol.dart:187-216`） |
| 对端 | Rust 主机 `shepaw-cli` | **不是** Rust 主机 —— 它没有 `/acp/ws` 路由，也不认 `method` |
| 拉 transcript | 有：`PeerAgentClientService.syncHistory`（`peer_agent_client_service.dart:5155`）+ `peer_history_cursor` 表 | 没有 |

`ProtocolType.peer` 的注释（`lib/models/remote_agent.dart:41-46`）写得很清楚：**「Hub 上的 Agent，经已配对设备的 P2P 连到这台 App…… 回合交给那台 Hub，不在这台 App 里跑」** —— 这正好就是你说的「权威在主机，客户端只拉数据」。**peer 路径已经是这个架构了。**

### 那 `/acp/ws` 是谁在提供服务？

证据指向老的那个 TS `agent-bridge`（仓库 `shepaw/agent-bridge`）：它的文档和调试客户端都用 `ws://127.0.0.1:8081/acp/ws`（`agent-bridge/tools/debug-clients/test_agent.py:12`）；Rust 侧完全找不到 `/acp/ws` 的路由。

但我不敢把这条当定论，因为有反证：`lib/peer/screens/peer_qr_display_screen.dart:546` 和 `lib/peer/services/peer_advertise.dart:15` 都在做 `endpoint.replaceFirst('/acp/ws', '/peer/ws')` —— 说明某个地方会产出 `/acp/ws` 形态的地址，而且它被当成 `/peer/ws` 的另一种写法来改写。这两条路径可能本来就在收敛过程中。

## 所以轮 B 取决于一个问题

**ACP 这条路（`/acp/ws` + JSON-RPC）还要不要长期存在？**

### 形态一：保留 ACP

那「消息权威在主机」对 ACP agent 就不成立（除非在 TS bridge 上现加一套历史接口）。轮 B = 在老系统上补一个带游标的 transcript 接口，还要在 App 侧补同步与合并逻辑。
代价：投入花在一个打算被取代的系统上；而且 ACP 与 peer 两套同步逻辑会长期并存。
mailbox 下线仍然成立（它跟协议无关），但「断线期间的回复不丢」这条**在 ACP 路径上做不到**，除非补这套接口。

### 形态二：ACP 收敛到 peer（`/peer/ws` + Rust 主机）

轮 B = 把 ACP agent 迁到 peer 协议。主机侧能力已经齐了，主要工作量在 App 侧：把 `syncHistory` 那套从 peer 复用到原 ACP agent 上，然后下掉每轮打包 history（`agent_messaging_service.dart:1413`）和 ACP 那套 JSON-RPC 连接。
代价：迁移面大，而且我前面几轮刚做的 ACP 连接可靠性改造（建连超时、重连窗口、续传）会随 ACP 路径一起退役 —— 那套能力在 peer 路径上需要重新确认是否齐备。

## 我需要你定的事

1. `/acp/ws` 现在到底是 TS `agent-bridge` 在服务，还是 Rust 主机也有一条（我可能漏看了）？这个事实直接决定形态一还是二。
2. 如果是 TS bridge：**它还在服役吗**？还是已经在迁往 Rust 主机的过程中、只是 App 还没切？
3. 你倾向形态一还是形态二？

这三个里第 1 条你一句话就能答，剩下的我再去把细节挖到底。

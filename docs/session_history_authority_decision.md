# 统一到 Rust 主机 / peer 路径（轮 B 完整设计）

状态：**方向已定，方案待你过**
关联：`docs/mailbox_retirement_decision.md` 的轮 B、轮 C、轮 D 都建立在这份之上

## 一、前提（已确认）

- **agent-bridge（TypeScript）已废弃**，被 `../shepaw-cli`（Rust）取代。已写进 `CLAUDE.md` 与 `shepaw-cli/README.md`。
- Rust 主机**只有一个 WebSocket 端点 `/peer/ws`**（`crates/peer/src/server.rs:450` 路径白名单硬编码），帧格式 `#[serde(tag = "type")]`。
- 因此「给 ACP 补历史接口」这条路不存在了 —— **轮 B = 把 App 的 agent 通信统一到 peer 路径（`/peer/ws`）**。

## 二、现状：两条路径对照

| | `ProtocolType.peer`（目标） | `ProtocolType.acp`（待退役） |
| --- | --- | --- |
| 端点 | `/peer/ws` | `/acp/ws` |
| 帧 | `type` 标签 | JSON-RPC `method` |
| 对端 | Rust `shepaw-cli` | 已废弃的 agent-bridge |
| transcript | 有：`syncHistory` + `agent_session_history_req` + `peer_history_cursor` 表 | 无，客户端本地库即权威 |
| 每轮打包 history | 可选（`peer_agent_client_service.dart:2460`，仅非空才带） | 必带（`agent_messaging_service.dart:1413`） |
| 建连超时 | 10s + 握手 15s（`peer_connection.dart:268-269`） | 15s（本轮新加，`acpConnectTimeout`） |
| 断连时对在跑回合 | **挂起**，等重连续传 | 20s 宽限后判死（本轮新加） |
| 重连 | 无限退避 2s→30s（`peer_connection_manager.dart:1317`） | 最多 5 次、间隔 3s |
| 续传 | `agent_turn_resume_req` + drop-prefix 幂等 | `agent.taskResume` |
| 停滞探测 | 180s（`stallProbeInterval`） | 180s（`stallTimeout`） |
| 回合超时 | 30min（`chatTimeout`） | 30min（`acpDmTaskTimeout`，本轮新加） |
| 主机不可达时发送 | 直接失败「配对设备未连接，无法发送」（`:2555`） | 落系统消息（轮 A 新加） |

## 三、peer 路径已有能力（逐条核过）

1. **建连**：`io.WebSocket.connect(endpoint).timeout(timeout)`，默认 10s（`peer_connection.dart:289`）；Noise 握手 15s（`:477`）。
2. **断连不判死**：`_suspendPendingForPeer`（`peer_agent_client_service.dart:6508`）把在途回合标 `suspendedSince` 挂起，**不 completeError**；重连成功走 `_resumeSuspendedTurns`（`:6533`）发 `agent_turn_resume_req`，断点 = `receivedLength`。
3. **续传幂等**：`applyResumeDelta`（`peer_turn_resume.dart:16`）按 `receivedLength - baseLength` 跳前缀 —— 重连后 live chunk 与 delta 重叠天然幂等，不需要我 ACP 那套「禁重入」的补丁。
4. **续传应答看门狗**：无应答会重发（重连竞态会偶发吞帧），重试耗尽或旧主机不支持续传才明确失败。
5. **挂起硬上限**：`suspendWaitHardCap = 25h`（`:1562`）。对比 ACP 的 20s 宽限 —— 迁移后切网体验会明显变好。
6. **停滞探测** 180s、回合超时 30min —— 与 ACP 对齐。
7. **transcript 同步**：`syncHistory`（`:5155`）用 `peer_history_cursor` 存游标，按 `agent_session_history_req` 增量拉，游标失效会自动 rebuild。
8. **切网主动体检**：`NetworkMonitorService._reconnectAll` 本来就调 `PeerConnectionManager.resumeAll`（ACP 那条是我这轮新加的）。
9. **主机侧排队**：Rust 主机 10-12 两个提交做了「`agent_chat` 按会话在主机排队」，所以 **busy 这个状态在 peer 路径上不会再出现**。
10. **UI 收尾兜底**：`ActiveTask.waitForSave()` 30s 是两条路径共用的。

## 四、迁移后要处理的差异

1. **轮 A 加的 busy 系统消息要改**。peer 路径主机自己排队，不会回 busy；「主机正忙，等当前这个回合跑完再发」这句在统一后是死分支。保留 ACP 期间是对的，退役时一起删。
2. **`acpConnectTimeout` 15s vs peer 10s**：统一后只剩 peer 的 10s，ACP 那个常量随路径一起删。
3. **每轮打包 history 可以下掉**：peer 那侧 history 本来就是可选参数，主机有自己的 transcript。这是最大的一笔简化 —— 顺带 `history_compactor`、`totalMessageCount` 记账都能一起退。
4. **我前三轮的 ACP 可靠性改造会随路径退役**：建连超时、重连宽限、续传禁重入、看门狗兜底 —— **peer 路径上这些能力本来就齐**（第 1-6 条），所以不会出现「迁移把刚补的洞又开回去」。这点核过了，是本次最大的收获。

## 五、施工顺序

### 轮 B1：让 ACP agent 能走 peer（数据侧）

现存 ACP agent 是 `RemoteAgent` 行、endpoint 为 `/acp/ws`；peer agent 靠 `metadata['source_peer_id']` + `metadata['remote_agent_id']` 定位到某台已配对 Hub。需要：
- 一条「把已有 ACP agent 重新挂到某台 Hub」的迁移路径（扫描 Hub 上的 agent 列表 → 配对/改写行）。
- 老行不能原地改协议：要么重新配对，要么提供一次性转换。

### 轮 B2：下掉每轮打包 history

`_sendViaACPProtocol` 里的 `chatHistory` / `totalMessageCount` 改为不带，由主机自己的 transcript 兜；peer 路径确认不依赖它之后，两边一起清。

### 轮 B3：退役 ACP 路径

删 `ACPAgentConnection` 及其 JSON-RPC 方法表、`ProtocolType.acp` 分支、`acpConnectTimeout` / `acpDmTaskTimeout`、我前三轮的改造里只为 ACP 写的部分（`acp_agent_connection.dart` 整份）。
**注意**：`group_member_stall.dart` 和 `chat_service.dart:1410` 引用了 `acpTaskTimeout`，退役时要一并处理。

### 之后：mailbox 的轮 C / 轮 D

收信侧删除 + 清 `lib/services/mailbox/` + 清 channel 仓库的 mailbox 表 —— 这些在 ACP 退役后自然就没有消费方了。

## 六、风险

- **轮 B1 是产品问题不是技术问题**：用户已有的 ACP agent 要重新配对，这一步如果有摩擦，会直接决定迁移能不能落地。建议先确认「现在线上到底有多少 ACP agent、用户怎么加进来的」。
- **退役 ACP 会删掉我刚做的可靠性改造**。虽然 peer 侧能力齐备，但两边实现不同（比如 peer 是无限重连、ACP 是 20s 宽限），统一后行为会变，值得在真机上再验一次切网。
- **peer 路径依赖已配对 Hub**：如果用户的场景是「直连一台主机、不经过 Hub 配对」，peer 路径不一定适用，需要先确认。

## 七、需要你定的

1. **轮 B1 的迁移方式**：重新配对，还是做一次性自动转换？（取决于第 6 节那个「现在怎么加进来的」）
2. **ACP 退役是一次性还是并行一段时间**：并行的话两套都要维护，我刚加的超时/宽限就得留着。

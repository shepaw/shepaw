# 统一到 Rust 主机 / peer 路径（轮 B 完整设计）

状态：**方向已定**（agent-bridge 废弃 ⇒ 只剩统一到 `/peer/ws`）。总纲见 `docs/roadmap_host_authority.md`，冲突时以总纲为准。
关联：`docs/mailbox_retirement_decision.md` 的轮 C、轮 D 建立在这份之上

> **2026-10-13 补充实证**：agent-bridge 的残留进程已在本机清掉（21 个 `acp-proxy-ts` 服务实例、1 个 `gateway-daemon`、5 个 `peer-store-mcp`、3 个引擎孤儿）。它们的 `--session-store-path` 全指向 `~/.config/shepaw-hub/instances/<id>/sessions.json` —— **和 Rust 主机同一个目录**（`hub_root()`），清掉前两边一直在互相覆盖会话文件。这也坐实了「acp 行的来源就是 agent-bridge」。

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

### 轮 B1：让 ACP agent 能走 peer —— 已具备，不是改造是处置

**核查结论：自动发现 + 自动建行这套两端都已经有，B1 不需要「转换行」。**

- Rust 侧：`agent_list_req` → `agent_list()`（`crates/api/src/agent.rs:720`），列出本机「本地 agent 且允许外部访问」的实例（id / name / engine / bio / cwd / workspace_uri / avatar，按 `instance.enabled` 过滤）。路由在 `crates/api/src/lib.rs:834`。
- App 侧：配对设备连上后**自动**发 `agent_list_req`（`peer_agent_client_service.dart:6902`），把结果落成 `protocol == ProtocolType.peer` 的 `RemoteAgent` 行（`:7049`），使其像普通 agent 一样出现在会话列表；断开标记离线，删除配对时清理。服务头部的注释（`:3-7`）就是这么写的。
- peer 行的 endpoint 是合成的 `peer://<peerId>/<remoteAgentId>`（`:7047`），**不是 URL** —— 所以不存在「把 `/acp/ws` 地址改成 `/peer/ws` 地址」这种原地改写。

**所以迁移的实际动作是**：用户配对 Hub → Hub 上的 agent 自动出现为新行 → 处置旧的 ACP 行（删除 / 留着自然淘汰 / 标记废弃）。不是逐条转换数据。

顺带回答「Rust 里还有没有 ACP 直连这种形态」：**没有**。Rust 的 agent 来源是 `list_instances()` 读本机实例，只有「配对后对外暴露」这一种，没有独立的 `/acp/ws` 直连入口。

### 但 `/acp/ws` 今天根本连不上 Rust 主机

顺着「旧 ACP 行从哪来」往下挖，挖到一个更硬的事实：

- **直连**：路径白名单硬编码只认 `/peer/ws`（`crates/peer/src/server.rs:450`）。
- **经 Channel 隧道**：`local_peer_url` 剥掉代理前缀后 `if !stripped.starts_with("/peer/ws") { return None; }`（`crates/peer/src/tunnel.rs:359-361`）——同样只放行 `/peer/ws`。

**结论：endpoint 以 `/acp/ws` 结尾的行，现在是连不上的死行。** 反过来说，今天能用的 agent 一定不是 `/acp/ws`。

### 「旧 ACP 行」的三个来源（含两个有名无实的）

1. **`ProtocolType.acp` 是解析默认值**：`remote_agent.dart:53` 的 `orElse: () => ProtocolType.acp` —— 任何没写 protocol 字段的行都是 acp。
2. **惜宝被标成 acp**：`she_service.dart:208`，但 `endpoint: ''` + `connectionType: http`，是本地内置 agent，压根不走 ACP WS —— tag 有名无实。
3. **Channel 授权流程会建 acp 行**：`agent_access_service.dart:196`，带 endpoint + `target_agent_id` + `cached_peer_static_public_key`。这正是 mailbox 服务的那批（`agentHasChannelInbox` 就要求有公钥 + 中继端点）。endpoint 来自 `status.endpoint`，是 Channel 下发的，形态取决于对端注册的是什么。

所以「处置旧 ACP 行」很可能是个**伪问题**：如果现在没有第三方 / 非 Hub 的 agent 接入场景，那么 acp 行要么本来就死（第 3 条里 endpoint 仍指向 `/acp/ws` 的那部分），要么有名无实（第 1、2 条），B1 直接消失。

**待确认**：现在还有没有「非 Hub 来源」的 agent（第三方自建 ACP 服务、或直连某台主机不走配对）？见第七节。

### 轮 B2：下掉每轮打包 history

`_sendViaACPProtocol` 里的 `chatHistory` / `totalMessageCount` 改为不带，由主机自己的 transcript 兜；peer 路径确认不依赖它之后，两边一起清。

### 轮 B3：退役 ACP 路径

删 `ACPAgentConnection` 及其 JSON-RPC 方法表、`ProtocolType.acp` 分支、`acpConnectTimeout` / `acpDmTaskTimeout`、我前三轮的改造里只为 ACP 写的部分（`acp_agent_connection.dart` 整份）。
**注意**：`group_member_stall.dart` 和 `chat_service.dart:1410` 引用了 `acpTaskTimeout`，退役时要一并处理。

### 之后：mailbox 的轮 C / 轮 D

收信侧删除 + 清 `lib/services/mailbox/` + 清 channel 仓库的 mailbox 表 —— 这些在 ACP 退役后自然就没有消费方了。

## 六、风险

- **退役 ACP 会删掉我刚做的可靠性改造**。虽然 peer 侧能力齐备，但两边实现不同（比如 peer 是无限重连、ACP 是 20s 宽限），统一后行为会变，值得在真机上再验一次切网。
- **peer 路径依赖已配对 Hub**：agent 只能「配对后由 Hub 暴露」获得（`peer://<peerId>/<remoteAgentId>`），没有「填一个 URL 直连」的入口。如果用户的场景里有「直连一台主机、不经过配对」，那 peer 覆盖不到，需要先确认这种场景是否存在。

## 七、需要你定的

1. **现在还有没有「非 Hub 来源」的 agent？** 即第三方自建 ACP 服务、或直连某台主机而不走配对。
   - 有 → ACP 路径要保留，B1 是真实工作，前面几轮的可靠性改造继续有效。
   - 没有 → `ProtocolType.acp` 整体是死路径（剩下的行要么连不上、要么只是 tag 碰巧是 acp），**B1 直接消失**，可以直接进入 B3 退役。
2. **ACP 退役是一次性还是并行一段时间**：并行的话两套都要维护，我刚加的超时/宽限就得留着。

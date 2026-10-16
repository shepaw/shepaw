# App 通用对接 ACP agent：能力隧道化设计

状态：**待裁定**（方案与开放问题需要你拍板，未动代码）
已定：① peer 层必须保留（理由见 §七，断线韧性结构性依赖主机常驻）；② 通用化走 §三的方案 B（主机降级为传输者）。
范围：App `lib/peer/**` + `lib/services/messaging/**` + `lib/widgets/**`，主机 `shepaw-cli/crates/engines/src/stdio.rs`、`crates/protocol/src/frames.rs`
相关：`docs/roadmap_host_authority.md`（总纲，冲突时以它为准）、`docs/session_history_authority_decision.md`（ACP→peer 迁移）

## 一、问题

今天 App 的对话能力不是「ACP 能力」，而是「shepaw 私有 peer 帧能力」。中间夹了一层**有损翻译**：主机把标准 ACP 语义翻译成自己的帧再发给 App。后果有两个，正好卡住你问的两件事。

**1）完整能力接不上。** 翻译层把 ACP 的能力面切掉了大半：

| ACP 语义 | 主机侧现状 | 是否到达 App |
| --- | --- | --- |
| `agent_message_chunk` / `agent_thought_chunk` | `stdio.rs:1571/1521` | 是（`agent_chunk` / 折叠 Thought） |
| `tool_call` / `tool_call_update` | `stdio.rs:1554` 只取标题做折叠段 | **部分**，终态不渲染 |
| `session/request_permission` | `stdio.rs:2109` → `ask_phone`(:2143) | 是（`agent_approval_req`） |
| `elicitation/create` · **form** | `stdio.rs:1737` → `elicitation_form`(:1778) | 是（`agent_form_req`） |
| `elicitation/create` · **url** | `stdio.rs:1779` 非 `form` 直接 `None` → decline | **否** |
| `plan` | 只喂 `tool_signal`(:1615/1638) 判空闲 | **否** |
| `session_info_update`（`agentPhase`） | 只喂 `tool_signal`(:1639) 判空闲 | **否** |
| `current_mode_update` / mode 列表 | 未处理 | **否**（只有 `engine_session_modes.dart` 静态目录） |
| `available_commands_update` | `stdio.rs:1110` 存盘，回合末发 `agent_commands_resp` | 部分（无增量） |
| `fs/read_text_file`、`fs/write_text_file` | capabilities 声明 `false`（`stdio.rs:669`） | **否** |
| `terminal/*` | capabilities 声明 `false`（`stdio.rs:670`） | **否** |

**2）通用性接不上。** 端到端跑的是 shepaw 私有帧（`frames.rs`，`#[serde(tag = "type")]`，Noise 信封），不是 ACP。第三方 ACP agent 只要说的是标准 ACP，就必须先被翻译成这套私有帧才能进 App——换一个 agent 就要在 Rust 侧补一套翻译。

## 二、约束（来自总纲，不可绕）

1. **主机权威**：`shepaw-cli` 持有会话与消息，App 只连上去拉数据渲染。
2. **只有 `/peer/ws` 一个端点**（`crates/peer/src/server.rs:450` 白名单硬编码）。`/acp/ws` 连不上。
3. **App 不 spawn 引擎进程**：桌面端 `cli_host.dart:152` 只 `Process.start(['start'], detached)` 拉起 hub 守护进程，对话一律连 `ws://127.0.0.1:$port/peer/ws`（`cli_host.dart:37`）。

⇒ 「App 自己当 ACP client、直接 spawn 引擎跑 stdio」这条路和总纲冲突，不在选项里。更硬的理由是断线韧性会结构性丢失，见 §七。

## 三、三个方案

| | A 补私有帧 | B **ACP 隧道**（推荐） | C 双栈 |
| --- | --- | --- | --- |
| 做法 | 继续翻译，缺哪个补哪个（plan 帧、mode 帧、url 卡） | 主机不再翻译，把标准 ACP 消息原样封进 Noise 帧转发；App 实现标准 ACP 应答端 | peer 帧与 ACP 隧道并存，按 agent 选 |
| 通用性 | 差，每接一个能力改一次 Rust + 一次 Dart | 好，App 只认标准 ACP，换 agent 不动 App | 好，但两套都要维护 |
| 改动量 | 小 | 中（传输 1 条新帧 + App 一个应答器） | 大 |
| 兼容性 | 好 | 需灰度（见 §5） | 好 |
| 长期成本 | 翻译层持续膨胀 | 翻译层萎缩成纯传输 | 双份 |

**推荐 B。** 理由：总纲已经定了「主机权威 + 单端点」，B 是把主机从「翻译者」降级成「传输者」，正好顺着这条路线走到底；而 A 每加一种能力都要同时改两侧，且能力面永远滞后于 agent 侧。

## 四、方案 B 的关键设计

### 4.1 传输层：一条 `acp_envelope` 帧

主机侧 `stdio.rs` 改成：读子进程 stdout 拿到一行 JSON → 判断是 response / request / notification → **不再翻译成 `agent_chunk` / `agent_form_req` 等**，而是原样塞进

```json
{"type":"acp_envelope","request_id":"...","agent_id":"...","payload": <原始 ACP 消息>}
```

下行。上行对称：`{"type":"acp_envelope_resp","request_id":"...","payload": <App 给出的 JSON-RPC result>}`。

请求-应答关联复用现成的 `ApprovalBus`（`begin` / `resolve` / `pending_frames_for`）——它本来就是为「跨设备、可重连补发」设计的，只是票据里装的从私有帧换成 ACP 原文。30 分钟等待（`stdio.rs:34`）与孤儿卡补发逻辑原样保留。

### 4.2 能力协商（通用化的核心）

现在 `initialize` 的 clientCapabilities 是**主机写死**的（`stdio.rs:664-677`），和 App 实际能渲染什么无关。改成：

- App 建连时上报能力清单（`/peer/ws` 的 hello 里带，或新增一条 `client_capabilities_req`）；
- 主机填 `initialize` 时取 **App 能力 ∩ 主机能力**：App 说不会渲染 `plan`，就别声明相关能力，agent 也就不会发；
- 这样老版本 App 不会收到渲染不了的卡片，新 App 解锁新能力不需要改 Rust 的翻译表。

### 4.3 App 侧应答器（新增一个文件，集中一处）

`AcpEnvelopeDispatcher`：按 `payload.method` / `payload.params.sessionUpdate` 分派。

| 输入 | 落到 |
| --- | --- |
| `session/update` · `agent_message_chunk` | 现有流式拼接 |
| `session/update` · `tool_call` / `tool_call_update` | 现有折叠段（补齐终态） |
| `session/update` · `plan` | **新**：`PlanCard` |
| `session/update` · `current_mode_update` | **新**：模式选择器 |
| `session/update` · `session_info_update`（`agentPhase`） | **新**：「工具执行中」状态条（也顺带解决空闲超时的观感） |
| `session/request_permission` | 现有审批卡（`agent_approval_req` 语义等价） |
| `elicitation/create` · form | 现有 `FormBubble` |
| `elicitation/create` · url | **新**：见 §4.4 |
| `notifications/elicitation/complete` | **新**：url 卡的完成回执 |

### 4.4 url 模式：最麻烦的一块

按 MCP 2025-11-25 规范（`elicitation/create` 的 `mode:"url"`）：

- 请求带 `url` + `elicitationId`，**不带 schema**；
- client **必须**展示目标域名/host 并先征得同意，再导航；
- 回 `accept` 只表示「用户同意去打开」，**不代表交互完成**；
- 真正的完成靠 server 侧的 `notifications/elicitation/complete`（带同一个 `elicitationId`），client 可忽略未知/已完成的 id；
- 规范明令：url 模式下敏感数据**不经过 client**。

App 侧现状：没有 webview、没有 OS scheme 回跳，只有 `url_launcher` 外跳（`pubspec.yaml:92`，`message_bubble.dart:821`）。所以最小可落地形态是：

> 卡片显示域名 + message + 「打开 / 拒绝」→ 点打开：回 `accept` + `url_launcher` 外跳 → 卡片转为「等待外部完成」→ 收到 `notifications/elicitation/complete` 打勾；用户拒绝回 `decline`，点停止回 `cancel`。

两个待定：**要不要引入 webview**（内嵌能保上下文、但多一个重依赖且要处理 Cookie/同源），以及 **30 分钟等待窗口对 url 模式是否合适**（外跳后用户可能根本不回来，建议 url 模式单独一个更短的等待 + 到点按 `cancel` 而非现在的 `offline_reply`）。

### 4.5 `fs/*` 与 `terminal/*`

App 一旦声明这两个能力，就意味着**手机要代理主机的文件读写与终端**。这不是渲染问题，是权限问题。建议：默认全部关闭（维持现状），桌面端单独开一个开关，走独立决策文档。

## 五、灰度与兼容

1. **帧共存**：`acp_envelope` 与现有 `agent_chunk` / `agent_form_req` / `agent_approval_req` 并存，主机按 App 上报的能力位决定走哪套。老 App 完全不受影响。
2. **幂等与补发**：`pending_frames_for` 重连补发的票据内容从私有帧换成 ACP 原文，App 侧 `_orphanedForms` / `_orphanedApprovals`（`peer_agent_client_service.dart:1684-1702`）要能认 `acp_envelope` 的 `request_id`。
3. **群编排**：`request_id` 以 `group-` 开头的 elicitation 现在直接 decline（`stdio.rs:1744`）。隧道化后这条要保留，否则群聊回合会卡在等手机填表。
4. **本地直连 CLI（无 `ApprovalBus`）**：现在一律 decline（`stdio.rs:1747`）。隧道化后同样保留，但可以把「无人应答」从 `decline` 改成 `cancel`，语义更准。

## 六、分轮落地（建议）

| 轮 | 内容 | 风险 |
| --- | --- | --- |
| R1 | 主机加 `acp_envelope` 出/入帧 + 能力上报通道；仅对**显式声明支持隧道**的 App 生效 | 低，纯新增 |
| R2 | App 侧 `AcpEnvelopeDispatcher`，先只接管 `tool_call` 终态 + `plan` + `session_info_update`，其余仍走旧帧 | 低，可逐类灰度 |
| R3 | 把 form elicitation 与 request_permission 切到隧道，旧帧停用 | 中，需要孤儿卡补发同步改造 |
| R4 | url 模式卡片 + `notifications/elicitation/complete` | 中，依赖 §4.4 的裁定 |
| R5 | 删 Rust 侧翻译表（`elicitation_form` / `permission_result` 等） | 低，R3/R4 之后 |

## 七、若去掉 peer 层（App 直连 ACP）：断线会怎样

§二按总纲排除了这条路。除了架构冲突，还有更硬的理由：**断线韧性会结构性丢失，不是工作量问题。**

### 7.1 App 自己能重建的（连接层）

| 机制 | 现状 | 直连能否自建 |
| --- | --- | --- |
| 建连 10s / 握手 15s | `peer_connection.dart:268-269,289` | 能 |
| 心跳 30s、120s 无活动判死 | `peer_connection.dart:694,723,725-741` | 能 |
| 半开连接探测 3s | `peer_connection.dart:701-719` | 能 |
| 重连指数退避 2→30s、无限次 | `peer_connection_manager.dart:1317-1326` | 能 |
| 断连后 UI 挂起等待 | `peer_agent_client_service.dart:1562,6598-6614` | 能（但等不到东西，见 7.2） |

### 7.2 结构性丢失的三类

**① 回合脱离发起方存活。** 主机把 session 缓存在自己进程内存（`stdio.rs:70`），stdout 读循环是主机线程（`:602-625`），在途回合活在 `crates/api/src/live_turns.rs`（独立于发起方）。换成 App 持有子进程：App 退出或被系统杀 → 管道读端消失 → 回合立刻死；Rust 侧 `Drop → kill_tree`（`:1306-1310`）在 App 侧根本没有对应物。

而且 **ACP 救不了**：`session/load` 只能按 `sessionId` 回放历史正文（`stdio.rs:713-754`，靠 `user_message_chunk`），**没有「继续一条未完成的 prompt」的语义**。断线前的那轮模型输出拿不回来。

**② 单次投递物件的补发。** 提问卡只发一次（`crates/gate/src/bus.rs:45-46`），留底的是**生成器那一方**。主机模式下：主机留底（`bus.rs:71-80`）+ 手机上线即补（`crates/cli/src/main.rs:1098-1108`）+ 续传时带卡（`crates/api/src/lib.rs:1006,1032`）。App 直连时，**丢失方和补发方是同一个进程**，断线期间 agent 发出的 elicitation 永久丢失，而 agent 还在 `approval_wait` 30 分钟里干等（`stdio.rs:29-38`）。

**③ 会话排队。** `crates/api/src/session_queue.rs:1-4` 落盘排队，主机常驻才能「掉线期间后续消息仍排队」。App 直连时队列随 App 一起没了。

### 7.3 移动端根本不成立

`cli_host.dart:104` `localCliSupported => !isAndroid && !isIOS` —— 手机不能 spawn 引擎进程。去掉 peer 层 = 手机彻底无法对话（不只是断线难处理）。

### 7.4 结论

**断线韧性正是 peer 层存在的理由**：主机常驻提供一个「发起方可以掉线」的第三人。App 直连 ACP 时，连接层都能补，但补完之后挂起的另一端**没有人为它续传**。所以通用化必须走 §三的 B（主机降级为传输者），不能走「App 直连」。

## 八、AskUserQuestion 不是引擎标配：三方协商的结果

实测本机已安装的引擎与 ACP 桥接包（2026-10-14）：

| 引擎 | 版本 | 有 AskUserQuestion 工具 | 桥接层映射到 elicitation |
| --- | --- | --- | --- |
| codebuddy | 2.146.0 | 有 | 是，`elicitation/create` ×45、`elicitation/complete` ×22 |
| claude-code（`@agentclientprotocol/claude-agent-acp`） | 2.1.241 | 有（×44） | 是，见下面引文 |
| codex（`@agentclientprotocol/codex-acp`） | 0.146.0 | **无**（×0） | 只转发 MCP server 的 elicitation（`elicitationHandler` ×6） |

**决定性的一条**是桥接层的能力门控。`claude-agent-acp/dist/acp-agent.js:7024-7031`：

```js
const elicitationSupport = {
    form: !!this.clientCapabilities?.elicitation?.form,
    url:  !!this.clientCapabilities?.elicitation?.url,
};
// AskUserQuestion surfaces as a `permission_ask_user_question` dialog that
// we render as a form elicitation. Without form-elicitation support there
// is no way to present it over ACP, so keep it disabled in that case.
const disallowedTools = elicitationSupport.form ? [] : ["AskUserQuestion"];
```

**client 不声明 `elicitation.form` → 桥接层直接把 AskUserQuestion 塞进 `disallowedTools`，模型压根看不见这个工具。** codebuddy 同样门控（`dist-server` 里 30 处 `elicitation?.form`）。同一文件还显示另外两处门控：MCP server 的 elicitation 只在 `form || url` 时挂 `onElicitation`（`:7139`），refusal-fallback 同意提示只在 `form` 时挂 `onUserDialog`（`:7148`）。

### 结论：三条件与

AskUserQuestion 能用 = **引擎有这个工具** × **桥接层映射到 ACP** × **client 声明了对应能力**。缺任何一条，agent 就换一种问法（纯文本）或者压根不问。ACP 没有「工具能力发现」机制，client 无法预知某个 agent 会不会提问——只能一直准备好接 elicitation。

### 对本设计的两条硬约束

1. **url 模式的第一步不是写 UI，是补 capabilities。** shepaw 现在只声明 `"elicitation": {"form": {}}`（`stdio.rs:671`），**没有 `url`**。所以即便 codebuddy / claude / codex-acp 三方都实现了 url 模式（codebuddy 有 `elicitation/complete` ×22、codex-acp 有 `elicitation_complete` ×4），现在也永远不会触发——claude 侧会走「SDK 默认 auto-decline」降级。
2. **但也不能先加 capabilities 再补 UI。** 一旦声明了 `url` 而 App 渲染不了，agent 会卡在等应答直到 `approval_wait` 30 分钟超时。⇒ §4.2 的「App 上报能力 → 主机据此填 capabilities」是**硬前置**，不是优化项。

### 对通用化的含义

- 换引擎时**不需要改 shepaw**：桥接层自己会按 capabilities 决定给不给工具、走哪种模式。这正是 §三 B 方案想要的「换 agent 不动 App」。
- 但 App 的能力清单必须**逐项**声明 `form` / `url`，因为它直接决定 agent 能拿到哪些工具。声明得越保守，agent 能力越弱（会退化成纯文本提问）。
- App 侧必须保留纯文本提问的兜底——没声明能力或 agent 不用 elicitation 时，问题会以普通消息文本出现。

## 九、待你裁定

1. **方案选 A 还是 B？** 我推荐 B。若选 A，只补 plan / mode / url 三样，改动小但不解决通用性。
2. **url 模式**：引入 webview 内嵌，还是外跳浏览器 + `elicitation/complete` 回执？（我倾向后者）
3. **`fs/*`、`terminal/*` 开不开？** 我的建议是默认关、桌面端另议。
4. **优先级**：是先要「通用」（R1-R3，能让第三方 ACP agent 进 App），还是先要「完整能力」（plan / mode / url 卡片）？这两件事在 B 里是同一条路的先后段，但可以只做前半段就收手。

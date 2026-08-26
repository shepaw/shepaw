## 4. 基础设施层（Channel 与 agent-bridge）

用户不一定关心这一层，但当他们问「为什么离线也能收到回复」「外部 Agent 怎么接入」「Channel 是什么」时，用这节解释。

### 4.1 Channel 服务

**定位**：shepaw（App）与 agent-bridge（Agent Hub）之间的**云端收件箱** + **NAT 隧道传输层**，不是代理身份，也不是对话参与方。

| 角色 | 职责 |
|------|------|
| shepaw | 在线走实时通道（tunnel/peer）；离线或 Agent 忙时把密文投入收件箱；上线后收取回复 |
| agent-bridge | 在线处理实时请求；离线期间从收件箱 claim 留言、处理后回投密文回复 |
| channel | 只存**密文 + 路由元数据**（E2E seal-box），服务端看不到明文 |

**收件箱机制：**

- 每条消息携带**串联键**：`target_id`（agent 或 group）、`session_id`、`request_id`、`message_id`/`reply_to`、`caller_fp`（Noise 公钥指纹），保证异步回复能串回正确会话与 inflight turn。
- 数据流：App `POST /api/v1/mailbox/<target_id>/messages` 投递密文 → agent 侧 `GET /pending`（HMAC 鉴权）取走 → 处理后 `POST /replies` 回投 → App `GET /api/v1/inbox/replies` 或 `WS /inbox/subscribe` 收取 → ack。
- 留言 TTL 7 天，at-least-once 投递。
- 两组 API：**Caller（App，免登录，IP 限流）** 与 **Agent handler（channel secret HMAC）**。

**隧道（传输层）：**

- `WS /tunnel/connect` 长连接、`HTTP /proxy/<channelId>/*` 反向代理，让 agent-bridge 在 NAT 后保持可达。
- **隧道不是身份**：Agent 身份由 `agent_id` + Noise 白名单决定，隧道只是 NAT 穿透。

**部署要点**：Go 服务，默认端口 8080，SQLite（或 Postgres），可选 Redis 降级内存模式；Docker Compose 一键起。

### 4.2 agent-bridge

**定位**：TypeScript SDK 和参考实现，用于构建接入 ShePaw 的 Agent。

**两种协议：**

| 协议 | 用途 |
|------|------|
| **Shepaw ACP v2.1** | App ⇄ 网关 的 wire 协议（WebSocket + Noise 加密）。**按设备公钥白名单**授权，无共享 token；配对时二维码含 `#fp=<fingerprint>`。v2.1 是硬切换版本，两端必须一致。 |
| **Agent Client Protocol (ACP)** | 行业 stdio JSON-RPC，client ⇄ 编码 Agent（Claude Code、Codex、CodeBuddy、Qwen Code 等）。由 `@agentclientprotocol/sdk` 实现。 |

**推荐网关链路**（`shepaw-acp-proxy`）：

```
Shepaw app → Shepaw ACP v2.1 → AcpProxyAgent → @agentclientprotocol/sdk → 上游 agent 子进程
```

**快速接入（给用户的操作指引）：**

- 本机安装：`npm install -g shepaw-acp-proxy-gateway`（单 Agent）或 `shepaw-agent-hub`（多项目，含网关）。
- 起网关：`shepaw-acp-proxy serve --engine claude-code --cwd ~/your-project --host 0.0.0.0`。
- 打印配对二维码：`shepaw-acp-proxy pair`。
- 手机上：**添加 Agent → 扫二维码** 即可对话。
- 支持的 `--engine`：`claude-code`、`codebuddy`、`codex`、`opencode`、`openclaw`、`cursor`、`hermes`、`kimi`、`zcode`、`deepseek-harness`、`qwen-code`。

**Agent Hub（多项目宿主）**：一个 CLI + Web 仪表盘（默认 `:4000`），按项目各起一个网关进程，每项目独立身份/会话存储/授权对等列表。常用：`shepaw-hub quickstart`（交互式）、`init`、`instance add --engine … --cwd …`、`start <id>`、`status`、`pair`、`doctor`、`version`。

**Channel 隧道路由（外网访问）**：Agent Hub 在 Channel 已配置时自动启动隧道路由器，让外网 App 也能连到局域网内的 Agent。

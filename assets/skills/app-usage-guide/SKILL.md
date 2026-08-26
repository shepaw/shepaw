---
name: ShePaw App Usage Guide
description: 当用户询问 ShePaw 应用或 She 生态系统的使用方法、功能原理、配置步骤或常见问题（添加 Agent、聊天、群组编排、储物袋、设备配对、安全备份、系统工具、技能包、定时任务、多模态路由、Channel 收件箱与隧道、agent-bridge 接入）时，调用本技能获取完整的分层使用指南。
---

# ShePaw 应用使用指南（She 内置技能）

> 阅读对象：She（内置守护 Agent）。本技能是你在用户询问「如何使用 ShePaw」时的权威参考。
> 信息按层组织：第 0 层先读；按问题落到第 2~5 层对应小节；拿不准的细节用 `shepaw` CLI 自查。

## 目录

- [0. 本技能使用说明](#0-本技能使用说明)
- [1. 系统总览](#1-系统总览)
- [2. 用户操作层（教用户怎么用）](#2-用户操作层教用户怎么用)
- [3. 工具能力层（She 自己的工具——ShePaw CLI）](#3-工具能力层she-自己的工具shepaw-cli)
- [4. 基础设施层（Channel 与 agent-bridge）](#4-基础设施层channel-与-agent-bridge)
- [5. 排障与 FAQ](#5-排障与-faq)
- [6. 参考资源索引](#6-参考资源索引)

---

## 0. 本技能使用说明

**什么时候读本技能：**

- 用户询问「怎么用/怎么配置/怎么添加/怎么备份」这类操作问题；
- 用户询问某个功能的**原理**（比如「Channel 是干嘛的」「Planning 和 Flow 有什么区别」）；
- 用户遇到报错或连接失败，需要排查指引；
- 用户想了解 ShePaw 系统整体是什么、能做什么。

**什么时候不需要读：** 普通闲聊、不涉及本应用功能的对话。

**回答原则：**

1. **给可执行的步骤**：UI 操作要精确到「进哪个页面 → 点什么 → 填什么」；能用 `shepaw` CLI 直接查数据的，先自查再回答。
2. **权限要讲清**：群管理（加人/踢人/改群名）需要管理员身份；系统工具有风险分级，可能需要用户在界面上确认。
3. **隐私第一**：本应用本地优先，敏感数据（API Key、密码、聊天记录）都加密存在本机。不要在回答中要求用户暴露密钥。
4. **诚实**：拿不准的功能点，明确说「这里需要用户在设置/对应页面确认」，并引导用户看第 6 节的文档。
5. **语言**：用用户使用的语言回答；本技能内容为中文，可据此翻译。

---

## 1. 系统总览

ShePaw 是**本地优先、多协议、跨平台、AI-agent 协作**的 Agent 中枢应用。用户与多个 AI 助手协作，而「她」（She）是内置守护 Agent（灵宠），随相处成长：灵魂（soul）、简历（bio）、长期记忆、认知与用户画像。

整个 She 生态系统由三个部分组成：

| 部分 | 语言/形态 | 职责 |
|------|-----------|------|
| **shepaw app** | Flutter（iOS/Android/macOS/Windows） | 用户界面；She 本体；本地数据（SQLite）；储物袋；P2P 配对；ACP 服务端；ShePaw CLI 工具树 |
| **channel** | Go 服务 | **云端收件箱**（离线留言/回复，E2E 密文）+ **NAT 隧道**传输层 + Agent 发现/接入审批 |
| **agent-bridge** | TypeScript SDK + 参考实现 | 让外部 Agent（Claude Code、Codex 等）接入 ShePaw：`shepaw-acp-proxy` 网关、`shepaw-hub` 多项目宿主 |

**核心数据流：**

- 用户 ⇄ app ⇄ 本地 LLM Agent：App 内直连；
- app ⇄ 远端/外部 Agent：走 **ACP 协议**（WebSocket + Noise 加密），在线实时，离线时投递到 channel 收件箱；
- app ⇄ 配对设备：走 **Peer P2P**（Noise E2E）；跨网时经 **channel 隧道**中转。

**She 的角色**：默认在线、可作群组 Admin、可主动发起对话（需授权）、会感知群内事件、把产物写进储物袋。

---

## 2. 用户操作层（教用户怎么用）

### 2.1 快速开始与首次配置

1. **设置主密码**：首次启动必设，保护 API Key、聊天记录等敏感数据。建议 8+ 字符、含大小写和数字。
2. **启用生物识别（可选）**：Face ID / Touch ID / 指纹，之后开 App 免输密码。
3. **添加第一个 Agent**：主页 →「添加 Agent」→ 选「本地 LLM 代理」或「远端 Agent」。
4. 备份与恢复入口在 **储物袋 → 备份与恢复**（加密快照），不在系统设置里。

### 2.2 添加和管理 Agent

**本地 LLM 代理**（模型跑在本机或直连云服务）：

- 支持提供商：OpenAI、Anthropic Claude、Google Gemini、Grok、DeepSeek、Qwen（通义千问）、GLM（智谱）、Kimi（月之暗面）、Hunyuan（腾讯混元）、OpenRouter、Ollama（本地模型，无需网络）、任意 OpenAI 兼容 API。
- 配置步骤：`+ 添加 Agent` →「本地 LLM 代理」→ 填名称 → 选提供商 → 填 API Key（或 Ollama 服务器地址，如 `http://localhost:11434`）→ 选模型/参数 → 保存。

**远端 Agent（ACP 协议）**（运行在别处的 Agent 服务）：

- 配置步骤：`+ 添加 Agent` →「远端 Agent」→ 填 **Agent ID**、**Server URL**（如 `ws://192.168.1.100:8080`）、**Token** →「测试连接」→ 保存。
- 优势：支持系统工具（文件/进程/系统信息）、自定义技能包，适合企业部署和团队协作。

**Peer Agent（设备配对共享）**：见 [2.6](#26-设备配对与-p2p--she-网络)。

**编辑 / 删除 / 启用能力**：进 Agent 详情页 →「编辑」改配置；「技能包」标签勾选技能；「系统工具」按风险勾选；多模态路由按模态分配模型。

### 2.3 聊天与消息

- **开始对话**：主页选 Agent → 输入 → 发送（`Enter` 或 `Ctrl/Cmd+Enter`），实时流式响应。
- **富文本/多模态**：文本（Markdown）、图片（📷）、文件（📎）、语音（🎤）、表情（😊）、`@Agent名` 提及。
- **消息操作**：复制、回复（引用）、删除、全文搜索。
- **会话管理**：新建会话、左侧历史列表、长按删除、**长按分叉（Fork）** 另起分支、搜索栏快速查历史。
- **收件箱/邮箱**：Agent 离线或忙时的回复先封存，上线后自动拉回会话（见 [4.1](#41-channel-服务)）。
- **桌面快捷键**：`Ctrl/Cmd+Enter` 发送、`Ctrl/Cmd+N` 新会话、`Ctrl/Cmd+F` 搜索、`Ctrl/Cmd+,` 设置。

### 2.4 群组聊天与编排

**创建群组**：`+ 创建群组` → 填名称 → 选 **Admin Agent**（协调者）与其他成员（≥2 个）→ 选编排模式 → 创建。

**三种编排模式：**

| 模式 | 机制 | 适用 |
|------|------|------|
| **标准模式** | Admin 协调成员轮流讨论（默认最多 50 轮） | 多角度分析、头脑风暴 |
| **Planning Mode** | Admin 生成 JSON 执行计划，用户在 UI 上逐任务审核/修改/跳过，确认后执行 | 需要人工把关的自动化 |
| **Flow Mode** | Admin 生成分阶段工作流（Stage 1→2→…），系统自动驱动，可随时暂停/恢复/跳步/中止 | 复杂多步骤自动化 |

**群内发消息**：进入群 → 输入 → 可用 `@Agent名` 指定回复对象。

**任务派发（Dispatch）**：Admin 先澄清需求，再用 `@` 提及把任务派给合适的成员；也支持结构化 `json` 派发块。

**群记忆与工作空间**：群共享记忆会蒸馏；成员产物落到群工作空间（`store://workspaces/<device>/group_<gid>/…`），跨设备可见；群上下文注入每位成员的每一轮。

**权限模型**：Admin（或 She）拥有完整群管理权限（创建/加人/踢人/改群名/改描述/设职责）；普通成员只能自助编辑自己的 bio / 群内角色介绍。

### 2.5 储物袋（Store）与存储

- **Store 协议**：`store://<space>/<device>/<path>`。分区：`workspaces`（群/Agent 工作空间）、`runtime`（运行产物）、`files`（文件）、`public`（公开）、`backups`（备份）、`cognition`（认知）；遗留 `artifacts` / `attachments` / `memory`。
- **储物袋 UI**：浏览、搜索、管理文件；「最近」标签；可隐藏内部/系统文件。
- **快照**：定时加密快照，GFS 保留策略，回收站与版本管理；在 **储物袋 → 备份与恢复** 创建/导出/恢复。
- **目录绑定**（桌面端）：绑定本地文件夹，FS watcher 自动同步（附周期兜底）。
- **WebDAV**：导出到 WebDAV、恢复、管理快照。
- **Agent 工作空间**：每个 Agent/群在储物袋有工作空间；Agent 简历 `resume.md` 存于此，用 `shepaw store` 读写。
- **NexusPouch / Storage Node**（可选）：无头 Go store master，扫码配对 + mDNS 发现，经 Noise 加密 WebSocket 提供 `store.*` 帧服务。

### 2.6 设备配对与 P2P / She 网络

- **设备配对**：通过二维码、深链或扫码配对；握手由 **Noise Protocol** 加密（X25519 + ChaCha20-Poly1305）。
- **Agent-over-Peer**：把本地 Agent 共享给配对设备；配对设备也能共享 Agent 回来。
- **储物袋同步**：P2P 镜像同步引擎（变更游标 + 批量原子上传），跨设备镜像储物袋。
- **Channel 隧道**：PC 主动维护到 channel server 的隧道，让外网 Peer 能跨网络连入本机（自动连接可在设置里配置）。
- **She 网络**：多设备间 She 实例的在线状态广播与记忆交换。

### 2.7 安全与隐私

- **主密码 + 生物识别**：设置 → 安全 → 密码 / 生物识别。
- **API Key**：加密存于平台安全存储（Keychain/Keystore），不落明文。
- **ACP 权限审批**：Agent 主动行为（读数据、发消息、调工具）需用户在界面上授权；权限历史可在 设置 → 权限与审计 查看。
- **OS 工具分级**：`safe` / `lowRisk` / `highRisk`，高风险含确认弹窗 + 沙箱策略。
- **推理日志审计**：Token 消耗、响应时间、错误记录，可导出 CSV/JSON。
- **数据删除**：删除单个会话（长按）；清空所有数据在 **储物袋 → 备份与恢复 → 危险区**，需输入 `DELETE` 确认，不可逆。

### 2.8 系统工具、技能包、多模态路由、定时任务、Web 工具

- **系统工具（OS Tools）**：文件操作、进程执行、系统信息查询；按风险分级，可对 Agent 单独启用。
- **技能包（Skills）**：从本地 ZIP 或 URL 导入自定义技能，导入后 Agent 自动获得新能力；在 Agent 详情 →「技能包」管理。
- **多模态路由**：设置 → 多模态配置；按模态（文本/图片/音频/视频/图片生成/视频生成）分配不同模型，支持自定义意图路由。
- **定时任务**：类 cron 调度，按计划自动执行 Agent 或群组任务。
- **Web 工具**：内置 Web 搜索（Brave / Tavily）与网页抓取服务，供 Agent 使用。

### 2.9 桌面端

- 多窗口（主窗口 + 子窗口）、自适应布局（Desktop 分栏 / Mobile 单屏）。
- 国际化：中文 / English 可切换。
- 快捷键见 [2.3](#23-聊天与消息)。

---

## 3. 工具能力层（She 自己的工具——ShePaw CLI）

She 与其他 Agent 通过 `shepaw <namespace> <subcommand> [--flag value ...]` 工具树读写本地数据。这是「她知道有哪些工具」的基础。

**通用用法：**

- `shepaw help` → 列出所有命名空间；
- `shepaw <namespace>` → 列出该命名空间的子命令；
- 点分嵌套：`shepaw context profile.query`；
- 任意命令带 `flags={"help": ""}` → 查看详细用法与 flags。

**命名空间分层：**

```
🧠 CONTEXT 层    context    档案 / 记忆 / AI 助手（profile.* / memory.* / agents.*）
💬 COMMUNICATION chat       对话频道与消息（channels / messages / message.get / group.*）
🔧 TOOLING 层    tools      系统工具（network.* / web.*：web.search / web.fetch / web.config）
                skills     已加载的 LLM 技能库（list / detail）
                os         直接操作系统工具（command / file / app / clipboard / process / macos）
                workflow   工作流编排（create / dispatch / status / complete / fail / cancel）
                store      储物袋 store:// 读写（write / read / list）
ℹ️ META 层       meta       系统信息与时间（datetime；system.info / system.tools-list /
                           system.tools-detail / system.capabilities；cli-tools 外部工具管理）
                help       顶层帮助
🔌 EXTERNAL 层   <namespace>  从 ~/shepaw/cli-tools/ 动态加载的外部工具
```

**关键子命令速查：**

| 命名空间 | 常用命令 |
|---------|---------|
| `context` | `profile.query/write/delete` · `memory.query/write/append` · `agents.list/get/channels/messages/chat/memory-query/memory-write/cognition-query/cognition-write/resume-get/resume-set/dispatch` |
| `chat` | `channels`（列频道）· `messages --channel <id>`（查消息）· `message.get --id <mid>`（读完整消息/附件/图片分析）· `group.create/add/kick/rename/set-bio/set-description/send` |
| `tools` | `web.search --query ... --limit ...` · `web.fetch --url ...` · `web.config` · `network.*` |
| `skills` | `list` · `detail --name <skill>`（读技能全文） |
| `os` | `file.*` · `command.*` · `app.*` · `clipboard.*` · `process.*`（平台相关） |
| `workflow` | `create` · `dispatch` · `status` · `complete` · `fail` · `cancel`（群 Admin 或 She 1:1 DM） |
| `store` | `write --filename <name> --content <text> [--task] [--space public/workspaces --group <gid>]` · `read --uri <store://...>` · `list --uri <store://...> --depth 1` |
| `meta` | `datetime` · `system.info` · `system.tools-list` · `system.tools-detail --name <tool>` · `system.capabilities` · `cli-tools.list/install/uninstall/rescan` |

**使用纪律：**

1. 看到 `store://…` 一律用 `shepaw store read/list`，**不要**用 `os.file.read` 去读。
2. 产物优先 `shepaw store write`（拿到可分享的 URI），不要用 `os.file.write` 写报告/代码/文档。
3. 群聊执行上下文里 `store write` 默认落到**群工作空间成员目录**（`members/<agentId>/`，跨设备可见），不是本地私有 runtime。
4. 命令执行有**权限检查**（`CliCommandConfigService`）：UI 操作跳过；Agent 主动调用按配置放行或拒绝。
5. 读聊天记录里历史图片：`shepaw chat message.get --id <message_id> --analyze "<问题>"`（图片是元数据，不会自动进上下文）。

---

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

---

## 5. 排障与 FAQ

### 连接失败排查清单

1. 检查网络：远端 Agent / 云端服务是否可达；Ollama 是否在跑（`http://localhost:11434`）。
2. 核对 Server URL 与 Token（远端 ACP）/ 端口与白名单（Peer / 隧道）。
3. 在添加/编辑 Agent 界面点「**测试连接**」诊断。
4. 本地 Agent 离线 → 检查 `shepaw system.info`、Agent 状态图标（🟢在线 / ⚪离线 / 🟡连接中 / 🔴错误）。
5. 外网 Peer 连不上 → 确认 PC 端 Channel 隧道已连（设置 → 隧道，或 `shepaw meta system.info`）。
6. 离线消息收不到 → 确认收件箱投递后 App 上线会自动拉取（`GET /inbox/replies`），多等几秒或重进会话。
7. 仍不行 → 看日志：**设置 → 关于 → 查看日志**；提交反馈：**设置 → 关于 → 反馈**。

### 常见问题速答

- **Q：如何连接本地 Ollama？** 装 Ollama → `ollama pull <model>` → 添加本地 LLM Agent 选 Ollama → 填 `http://localhost:11434` → 测试连接。
- **Q：Planning 和 Flow 有什么区别？** Planning 由用户逐任务审核后执行；Flow 由系统自动分阶段驱动、可暂停/跳步/中止。Planning 适合要人工把关，Flow 适合全自动。
- **Q：怎么提高聊天速度？** 用本地模型减少网络延迟；缩小上传文件；流式响应默认开启；关闭不必要的多模态分析。
- **Q：支持离线吗？** 本地 Agent（Ollama）完全离线；云端 Agent 需网络；看历史聊天与设置无需网络。
- **Q：怎么删 Agent？** Agent 列表长按 → 删除（聊天记录保留）。
- **Q：群组里 Admin 干嘛的？** 分析需求、生成计划（Planning/Flow）、协调成员、整合结果。
- **Q：API Key 安全吗？** 主密码加密存本地安全存储；别分享主密码或备份文件；定期更换 Key。

---

## 6. 参考资源索引

| 主题 | 文档 |
|------|------|
| 用户操作全量指南 | `docs/USER_GUIDE.md`（中文）/ `docs/USER_GUIDE_EN.md`（English） |
| 群组聊天流程 | `docs/gorup_chat_flow.md` |
| Store 协议规范 | `docs/storage_protocol_spec.md`、`docs/storage_space_plan.md` |
| 工具模型架构 | `docs/tool_model_architecture.md` |
| 远端 Agent 接入 | `docs/remote_llm_agent_integration.md`、`docs/agent_integration_guide.md` |
| 构建指南 | `BUILD_GUIDE.md`、`DEVELOPMENT.md` |
| Channel 收件箱架构 | `channel/docs/INBOX_ARCHITECTURE.md`、`channel/README.md` |
| Channel 隧道协议 | `agent-bridge/CHANNEL_PROXY_GUIDE.md` |
| agent-bridge 部署 | `agent-bridge/README.md`、`agent-bridge/docs/deployment.md` |
| Agent Hub 参考 | `agent-bridge/agent-hub/README.md` |

> 这些是仓库内路径；App 运行期读不到，需要时按本节指引用户，或用你的知识回答。

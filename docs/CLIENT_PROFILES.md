# ShePaw 客户端存储 Profile

> 权威补充：[`storage_protocol_spec.md`](storage_protocol_spec.md)（协议）+ [`storage_space_plan.md`](storage_space_plan.md)（方案）。
> 本文只约定 **ShePaw App 客户端** 的路径、权威分层与上下文镜像语义；节点不必理解业务路径。

## 1. 永久双层：权威分层 + runtime 镜像

| 数据 | 本机权威（读 / 搜 / UI） | runtime 镜像（非权威） |
|------|--------------------------|------------------------|
| 会话消息 | `shepaw.db` `messages` | `runtime/<owner>/<channel>/sessions/session.json`（可滚动 archive） |
| Agent 结构化记忆 | **`cognition/<agentId>/entries/*.json`** | `runtime/<owner>/memory.md`（人读摘要） |
| Soul | **`cognition/<agentId>/soul.md`** | `runtime/<owner>/soul.md` |

**硬性约定**

- App 聊天消息与搜索 **只信 SQLite**；永不把 session 镜像当主库。
- Agent **结构化记忆与 Soul 权威在储物袋 `cognition/`**（旧 `memory/` 只读兼容）；旧 SQLite 仅作一次性迁移源。
- runtime 镜像为 **单向**（debounce 覆盖写）；`memory.md` / `soul.md`（runtime 下）**禁止**回灌权威。
- 镜像用途：人可读浏览、`store://` **分享**、跨设备 **只读上下文**。
- 灾难恢复权威仍是 `backups/` 加密快照。

## 2. 设备目录（内置 space）

```
<device_id>/
├── workspaces/<workspace_id>/...     # owner 可读可写（含跨 device）
├── cognition/<agent_id>/             # Agent 记忆 + Soul 权威
│   ├── meta.json                     # next_id / migrated flags
│   ├── soul.md                       # Soul 权威正文
│   ├── entries/<id>.json
│   └── peers/<peer_id>/entries/…     # 配对设备子记忆
├── memory/<agent_id>/                # legacy（只读兼容，迁移后可空）
├── runtime/<agent_id|group_id>/
│   ├── memory.md                     # 记忆摘要镜像（非权威）
│   ├── soul.md                       # Soul 镜像（非权威）
│   ├── workspace.md                  # workspace_ids 绑定（引用，不复制）
│   ├── context.manifest.json         # ContextBundle 最小清单
│   └── <channel_id>/
│       ├── sessions/session.json     # 最近窗口（无 workflow 时）
│       ├── sessions/archive-<ts>.json
│       ├── attachments/<sha256>
│       ├── artifacts/<task_id>/<file>
│       └── <wf_<workflowId>__step_<stepId>>/   # 工作流步隔离（可选）
│           ├── sessions/session.json
│           ├── attachments/<sha256>
│           └── artifacts/<task_id>/<file>
├── files/...                         # 沉淀区（owner 可读，仅本端写）
├── public/...                        # 可引用 files URI，不强制 copy
├── backups/...                       # 私有灾备
├── artifacts/...                     # legacy（只读兼容旧 URI）
└── attachments/...                   # legacy 私有区
```

URI：`store://<space>/<device_id>/<relpath>`。

### ACL 摘要

| space | visibility | 写 |
|-------|------------|-----|
| `workspaces` | shared | **所有 owner 可写任意 owner 的该区** |
| `runtime` | private（可按前缀分享只读） | 仅属主 |
| `cognition` | private | 仅本端（Agent 记忆 + Soul 权威） |
| `memory` | private（legacy） | 只读兼容；新写入走 `cognition` |
| `files` / `public` | shared | 仅本端 |
| `backups` | private | 仅本端 |
| `artifacts` / `attachments` | legacy | 旧数据可读；新写入走 runtime |

## 3. Runtime owner 解析

| 场景 | `<agent_id\|group_id>` | 写入 device |
|------|------------------------|-------------|
| 本机 LLM 单聊 | `agent_id` | 本机 |
| 群聊 | `parentGroupId` 或群 `channel_id` | 群主设备（metadata `runtime_owner_device_id`；缺省本机） |
| Peer 隧道 agent | 对端 `remote_agent_id` | **对端权威 + 本机同 URI 缓存**：附件与 `sessions/session.json` 均落 `store://runtime/<对端fingerprint>/<A>/<peer__…>/…`；App1 在本机 store 根下按同一 `<device>/runtime/…` 路径缓存（`placement=local_fallback`），气泡 / 镜像 URI 与宿主一致。不在对端 device 树下伪造 soul/memory。 |
| 外接 ACP | agent id | Hub device；否则本机 fallback |

群聊 key：优先 `parentGroupId`，否则群 channel `id`。

工作流 peer session 的逻辑 id 仍为 `channel__wf_<wf>__step_<step>`（保证步间会话隔离）；
落盘时拆成 `runtime/<owner>/<channel>/wf_<wf>__step_<step>/…`，**channel 单独一级目录**。

## 4. ContextBundle（最小 manifest）

路径：`runtime/<owner>/context.manifest.json`

```json
{
  "schema_version": 1,
  "owner_id": "<agent_or_group_id>",
  "source_device": "<device_id>",
  "updated_at": "ISO-8601",
  "soul_uri": "store://cognition/<device>/<agent>/soul.md",
  "memory_uri": "store://cognition/<device>/<agent>/entries/",
  "workspace_refs": ["store://workspaces/<device>/<workspace_id>/"],
  "channels": {
    "<channel_id>": {
      "session_uri": "store://runtime/.../sessions/session.json"
    }
  }
}
```

群编排 / handoff 应优先传 **manifest URI**（ContextBundle），而不是贴全文或展开全部子 URI。

## 5. session.json / memory.md 格式

`sessions/session.json`（最近窗口；超阈值滚动到 `archive-<ts>.json`）：

```json
{
  "meta": {
    "channel_id": "...",
    "owner_id": "...",
    "updated_at": "...",
    "schema_version": 1,
    "window_size": 100,
    "archived_at": "ISO-8601?",
    "archive_uri": "store://runtime/.../sessions/archive-....json?"
  },
  "messages": [ { "id", "sender_id", "sender_type", "content", "message_type", "created_at", "store_uri?" } ]
}
```

附件只存 `store_uri`，不内嵌字节。滚动阈值：≥200 条或序列化 ≥256KB 时归档全量并保留最近 100 条。

`memory.md` / `soul.md`（runtime 下）：UTF-8 人读镜像；权威见 `cognition/` 空间。

## 6. 引用不复制

- 聊天引用已有 `store://`：只写 metadata，不复制 blob。
- `public/` 可用清单指向 `store://files/...`。
- `workspace.md` 只列 `workspace_ids`，不复制 `workspaces/` 树。

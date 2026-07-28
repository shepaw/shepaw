# ShePaw 存储空间协议规范（store.*）

> 版本：v4.1（与方案 v1.1 对齐：跨端读权威=master；CAS=远端读缓存；GFS 本机执行）
> 状态：Dart 与 Go 实现的权威定义。上游设计：`docs/storage_space_plan.md`。
> 共享 fixture：`docs/storage_fixtures/`（path 攻击 + ACL 用例）。
> 传输：复用 `PeerConnection` 控制帧（WS + Noise E2E）与 Channel Tunnel；本协议不新增传输。

## 0. 术语

| 术语 | 含义 |
|------|------|
| 设备目录 | `<device_id>/`，每端实体数据的唯一归属；`device_id` = Noise 静态公钥哈希（16 hex）。 |
| master | 镜像汇聚点 + 跨端读取权威。同一时间唯一；M2 默认本机（loopback），指定/迁移见方案 §6.5（M6）。 |
| space | 目录分区：`artifacts` / `files` / `attachments` / `backups`。 |
| staging | `<device_id>/<space>/.staging/<upload_id>/`，未 commit 的半成品，对 `list`/恢复不可见。 |
| `.recycle` | 回收站（store 根级系统目录），删除与被覆盖旧版本的去处；仅 master 本机用户可清空。 |
| trust_level | 配对信任分级（`paired_peers.trust_level`）：`owner`（自己的设备）/ `friend`（预留，本期拒绝一切 store.*）。 |

## 1. 帧格式

```json
{"type": "store", "ns": "store", "op": "<操作>", "v": 1, "req_id": "<uuid>", "...": "op 特有字段"}
```

- `type`/`ns` 恒为 `"store"`：peer 层按 `type` 路由控制帧；`ns` 供协议层与 Go 实现校验。
- `req_id`：请求方生成的 uuid。**响应帧**回带同一 `req_id`：
  - 成功：`{"op": "result", "req_id": ..., "data": {...}}`
  - 失败：`{"op": "error", "req_id": ..., "code": "...", "message": "..."}`
- `v` 协议版本，本版恒为 `1`。高于本版 → `error/unsupported_version`。
- 无 `req_id` 的帧视为通知，不回复（M2 未使用）。

### 错误码

| code | 含义 |
|------|------|
| `unsupported_version` | 协议版本不兼容 |
| `untrusted` | friend 级设备发送 store.*（拒绝并审计） |
| `not_paired` | 未配对设备 |
| `acl_denied` | 越权（见 §3 ACL 矩阵） |
| `bad_path` | 路径非法（绝对路径/`..` 穿越/非法字符/符号链接逃逸） |
| `bad_op` | 未知 op 或 op 参数非法（含伪造的导入授权类 op） |
| `hash_mismatch` | commit 校验 sha256 不符 |
| `not_found` | 目标不存在 |
| `staging_state` | upload_id 状态非法（重复 commit / 未知 id） |
| `master_offline` | master 不可达（客户端本地判定） |
| `not_master` | 本节点已非当前 master（fencing：拒绝 sync 写入/`sync.hello`） |
| `internal` | 其他内部错误 |

## 2. 操作清单

`space` 必填单值。`device` 参数仅用于**读取类**操作指定他端目录，缺省 = 调用者自身。

### 2.1 list — 列目录

```json
{"op": "list", "space": "artifacts", "device": "pc-b", "path": "task-41/"}
→ {"op": "result", "data": {"entries": [
    {"path": "task-41/report.md", "size": 12288, "sha256": "...", "mtime": 1721300000000}]}}
```

- 递归列出 `path` 前缀下的文件；不含 `.staging`、`.` 开头目录与 `.recycle`。
- 大量文件时分页：`cursor`（请求）/ `next_cursor`（响应），每页 ≤ 1000 条。

### 2.2 meta — 元数据（缓存校验，§6.1）

```json
{"op": "meta", "space": "artifacts", "device": "pc-b", "path": "task-41/x.py"}
→ {"op": "result", "data": {"kind": "file", "size": 4096, "sha256": "...", "mtime": 1721300000000}}
// path 为目录时：
→ {"op": "result", "data": {"kind": "dir", "files": [{"path": "...", "sha256": "...", "size": 1, "mtime": 0}]}}
```

不传内容，一次往返完成批量缓存校验。

### 2.3 read — 读文件

```json
{"op": "read", "space": "artifacts", "device": "pc-b", "path": "task-41/x.py", "offset": 0, "length": 65536}
→ {"op": "result", "data": {"data": "<base64>", "size": 4096, "eof": true}}
```

- `length` ≤ 65536（64KB）；`offset` 越界返回空 data + `eof: true`。

### 2.4 write.begin — 开始写入（断点续传）

```json
{"op": "write.begin", "space": "artifacts", "path": "task-41/x.py", "size": 4096,
 "sha256": "...", "upload_id": "<可选>"}
→ {"op": "result", "data": {"upload_id": "u-...", "received": 2048}}
```

- master 在 `<调用者>/<space>/.staging/<upload_id>/` 建立暂存。
- **offset 幂等续传**：`upload_id` 复用已有暂存时返回已接收字节数 `received`，客户端从该 offset 续传。
- 暂存超过 24h 未 commit 由 master 自动清理。

### 2.5 write.chunk — 写数据块

```json
{"op": "write.chunk", "upload_id": "u-...", "offset": 0, "data": "<base64 ≤ 64KB>"}
→ {"op": "result", "data": {"received": 4096}}
```

- `offset` 必须 ≤ 已接收长度（顺序追加，允许从已确认位置重写）；写入后 `received` 为新的连续长度。

### 2.6 commit — 原子转正

```json
{"op": "commit", "space": "artifacts", "upload_ids": ["u-..."], "retention": null}
→ {"op": "result", "data": {"committed": ["task-41/x.py"], "failed": []}}
```

- 校验：每个 upload 的组装内容 sha256 与 write.begin 声明一致，**全部通过才进入转正**。
- 转正：暂存文件 rename 到最终路径（同卷原子）；目标已存在时旧版本先移入 `.recycle`。
- 批内单文件转正失败：其余继续，响应 `failed` 标注；staging 保留可重试。
- `retention`（可选）：转正成功后按策略剪枝同分区**顶层目录**。
  - `{"policy":"keep_last","keep":4,"include_prefix"?: "...","exclude_prefix"?: "..."}`
  - `{"policy":"gfs","daily":7,"weekly":28,"monthly":12,"exclude_prefix"?: "reprotect-"}`
  - 删除经 `delete` 进回收站；本机变更仍入 SyncJournal。快照 commit 默认带 GFS（排除 `reprotect-`）；再保护 commit 默认 `keep_last`（仅 `reprotect-`）。

### 2.7 delete — 删除（入回收站）

```json
{"op": "delete", "space": "files", "device": "pc-b", "path": "old.zip"}
→ {"op": "result", "data": {"recycled": ".recycle/2026-07-26/pc-b/files/old.zip"}}
```

- 无自动保留期之外的语义：仅移入 `.recycle/<date>/<device>/<space>/<path>`（30 天清理由 master 本地策略执行）。
- 目录路径递归移动。

### 2.8 recycle.list / recycle.restore / recycle.empty

```json
{"op": "recycle.list"}
→ {"op": "result", "data": {"entries": [{"recycle_path": ".recycle/2026-07-26/pc-b/files/old.zip",
    "origin_device": "pc-b", "space": "files", "origin_path": "old.zip", "size": 1024, "deleted_at": 1721300000000}]}}

{"op": "recycle.restore", "recycle_path": ".recycle/2026-07-26/pc-b/files/old.zip"}
→ {"op": "result", "data": {"restored": "old.zip"}}

{"op": "recycle.empty"}  → {"op": "result", "data": {"purged_bytes": 1048576}}
```

- `recycle.restore` 移回原路径；原位置已有文件时先将其移入回收站（新版本优先保留语义）。
- **`recycle.empty` 仅 master 本机用户（loopback）可执行；远端调用一律 `acl_denied`。**

### 2.9 stats — 用量

```json
{"op": "stats"}
→ {"op": "result", "data": {
    "devices": {"pc-b": {"artifacts": 1024, "files": 2048, "attachments": 0, "backups": 4096}},
    "staging_bytes": 0, "recycle_bytes": 1048576,
    "unsynced_count": 0, "unsynced_bytes": 0, "change_seq": 12, "ack_seq": 12,
    "volume_total_bytes": 500000000000, "volume_free_bytes": 80000000000,
    "volume_used_ratio": 0.84, "volume_warn": true}}
```

- `unsynced_*` / 游标水位：本机同步引擎挂载时附加。
- `volume_*`：store 根所在卷探测成功时附加；`volume_warn == true` 表示已用 ≥ 80%（方案 §7）。探测失败则省略字段。

## 3. ACL 矩阵

调用者身份 = Noise 会话对端公钥哈希（= 其 device_id）。master 据此构造写目标目录。

| 操作 | space | 自有目录 | 他端 owner 目录 |
|------|-------|---------|----------------|
| write.\*/commit | 任意 | ✅（device 字段缺省或=调用者；不符即 `acl_denied`+审计） | ❌ 机制上不可能 |
| delete | artifacts/files | ✅ | ✅（共享文件手动删除） |
| delete | attachments/backups | ✅ | ❌ `acl_denied` |
| list/read/meta | artifacts/files | ✅ | ✅ owner 级 |
| list/read/meta | attachments/backups | ✅ | 仅持有效导入授权（§5） |
| recycle.list/restore | — | ✅ owner 级（回收站全局可见语义 M2 从宽） | 同左 |
| recycle.empty | — | 仅 loopback（master 本机用户） | ❌ 恒 `acl_denied` |
| import.request | — | ✅ owner 级（old_device ≠ 调用者） | — |
| import.pending | — | ✅ owner 级 | — |
| import.grant / import.reject / import.grants | — | 仅 loopback（用户在场确认是信任锚） | ❌ 恒 `acl_denied` |
| stats | — | ✅ owner 级 | — |

**friend 级设备：所有 store.* 帧一律 `untrusted` 并记审计日志。**

## 4. 写路径收敛（§6.2）

- master 侧写目标 = `<调用者 device_id>/<space>/`，由协议构造；`device` 字段与调用者不符 → `acl_denied` + 审计。
- 路径规范化：必须相对路径；逐段拒绝 `..`、绝对路径、盘符、NUL、反斜杠（统一为 `/`）；落盘前 `resolve` 后必须仍以设备目录为前缀（防符号链接逃逸）；`.` 开头段拒绝（保护 `.staging`/系统目录）。
- fixture 必含攻击用例：伪造 device_id 写入、读取他人私有目录、路径穿越、伪造导入授权（`import.*` 系列 op 在 M2 不存在，统一 `bad_op`）。

## 5. 换机导入授权（v2 新增，方案 §5.4）

新设备读取旧设备私有分区（`backups`/`attachments`）必须持一次性导入授权。

### 5.1 授权模型

- 授权（grant）为 **bearer token**（`ig-<uuid4>`，122 bit 熵），内容：
  `{grant_id, old_device, new_device, spaces, issued_at, expires_at, revoked}`。
- **信任锚是签发通道**：旧设备在场时经 Noise E2E 通道签发（通道身份即证明）；
  旧设备不在场时由 **master 本机用户在管理页手动确认**签发。
- 有效期 24h，限只读、限授权分区、可撤销；一次性语义 = 单次换机事件，
  过期/撤销后即失效。
- 持久化：服务侧（旧设备/master）存签发记录于 `<store>/.system/import_*.json`；
  请求方存收到的授权。

### 5.2 操作流程

```json
// 1. 新设备 → 服务侧（旧设备或 master）：登记导入请求
{"op": "import.request", "old_device": "<old_id>"}
→ {"op": "result", "data": {"request_id": "ir-...", "status": "pending"}}

// 2. 服务侧管理页（loopback）：查看待审批 / 用户确认后签发
{"op": "import.pending"} → {"requests": [...]}
{"op": "import.grant", "request_id": "ir-..."}
→ {"op": "result", "data": {"grant": {...}}}

// 3. 服务侧 → 新设备：授权推送（无 req_id 通知帧）
{"op": "import.grant", "grant_id": "ig-...", "spaces": ["backups","attachments"],
 "issued_at": 1721300000000, "expires_at": 1721386400000}

// 4. 新设备 → 服务侧：凭 grant 读旧设备私有分区
{"op": "list", "space": "backups", "device": "<old_id>", "path": "", "grant": "ig-..."}
{"op": "read", "space": "backups", "device": "<old_id>", "path": "<ts>/db.sqlite.enc",
 "offset": 0, "length": 65536, "grant": "ig-..."}
```

- `import.reject {request_id}`：服务侧拒绝（loopback）。
- `import.grants {role: "issued"|"received"}`：本机授权清单（loopback）。
- 读路径校验：grant 存在、未过期未撤销、`old_device`/`new_device`/`space` 全匹配；
  失败回 `acl_denied` 并审计。
- 快照跨端可解性：manifest 必须含 `kdf_salt`（v2 快照格式，两级 KDF：
  `H = PBKDF2(主密码)`、`key = HMAC(H, kdf_salt)`）；无 `kdf_salt` 的 M1 旧
  格式快照不支持换机恢复。
- 换机恢复**不恢复设备身份**：新设备保留自己的 device_id（restoreIdentity=false）；
  同机重装恢复才随快照恢复身份（§5.4）。
- 路径 B（旧设备不在场）的镜像数据依赖 M4 同步引擎就位后才可读；
  M3 落地协议与路径 A（旧设备在场直读）端到端。
- **远端 master 送达**：定期快照写入本机 `<device_id>/backups/` 后，经 M4
  同步引擎镜像到远端 master；M3 仅保证本机生成 + GFS，不单独实现上传通道。

## 6. 变更游标与批量原子上传（v3 新增，方案 §6.4）

### 6.1 游标模型

- **每端只为自己的 `<device_id>/` 维护单调递增变更游标** `change_seq`：
  本机每次 `commit` / `delete` 成功 +1。游标仅用于本设备目录的镜像对账，
  **不涉及跨设备排序**（区别于已废弃的 v4 全局序号）。
- 客户端记录已获 master 确认的水位 `ack_seq`；master 为每个设备目录记录
  已应用游标 `applied_seq`（持久化于 `<store>/.system/device_cursors.json`）。
- **未同步队列**：本地写先落盘返回成功，变更条目 `{seq, kind, space, files[]}`
  进入队列；同步引擎后台按 seq 顺序送达 master。
- **未同步数据不可淘汰**（本地磁盘压力清理时）；管理页展示未同步占用。

### 6.2 操作

```json
// 对账（连接建立后客户端主动发起）
{"op": "sync.hello", "device": "<调用者 device_id>"}
→ {"op": "result", "data": {"applied_seq": 41}}
```

- 客户端比较：`本地队列中 seq > applied_seq` 的条目**按游标差量重放**；
  上传即 §2.4~2.6 的 write.begin/chunk/commit（整批按序，**commit 标记最后送达**）。
- `commit` 帧 v3 起可携带 `upto_seq`；master 转正成功后把该设备
  `applied_seq` 推进到 `max(applied_seq, upto_seq)`，并在 result 中返回：

```json
{"op": "commit", "space": "backups", "upload_ids": ["u-1","u-2"], "upto_seq": 43}
→ {"op": "result", "data": {"committed": [...], "failed": [], "applied_seq": 43}}
```

- 客户端以 result 的 `applied_seq` 推进本地 `ack_seq` 并出队。
- `delete` 重放 = 普通 delete 帧（master 侧移入 `.recycle`），ack 随其后
  的下一笔 commit 水位推进（或专用 `upto_seq` delete 帧，二选一，实现侧
  统一为：delete 帧也可携带 `upto_seq`，master 回 applied_seq）。
- 冲突：last-write-wins（以 master 接收顺序为准），被覆盖旧版本进 `.recycle`。

## 7. 读路径缓存校验（v3 新增，方案 §6.4 读路径）

读取他端目录数据（非导入授权场景，指共享分区 artifacts/files）：

1. 有本地缓存 → 向 **当前 master** 发 `store.meta` 比对内容
   hash：**一致则直接使用缓存（零内容流量）**；不一致则重新下载并更新缓存。
2. 无缓存且 master 在线 → 直接拉取并写入缓存。
3. master 离线：有缓存则使用缓存并标注 `stale`（可能不是最新）；无缓存则
   **向源设备 `device` 直读回退**（仍失败再报错）。
4. `not_found`：有限退避重试；耗尽后若源设备 ≠ master，再直读源设备一次
   （`RemoteReadService`，`fromOwnerFallback`）。

- 跨端读权威仍为 master 镜像；owner 直读是可用性回退，不改变写权威。
- 缓存：`LocalCas` 按内容 hash 去重 + `.cache` 物化视图；LRU 默认 500MB，作用于远端读缓存。本机正式区为真实文件树，不经 CAS 写入；未同步数据由 `SyncJournal` 队列保护，不依赖 CAS `synced` 标志。

## 10. master 迁移与指针（v4 新增，方案 §6.5 / §6.6）

### 10.1 游标全表与升主

```json
{"op": "sync.cursors"}
→ {"op": "result", "data": {"cursors": {"<device_id>": 41, ...}}}

{"op": "master.migrate"}
→ {"op": "result", "data": {"master": "<new>", "epoch": 3,
    "old_master_reachable": true, "cursors": {...}, "broadcast_peers": 2,
    "seeded_files": 12, "hash_gate": {"ran": true, "ok": true,
      "devices": [...], "mismatches": [], "mismatch_count": 0}}}
```

- `sync.cursors`：返回本机作为（或曾作）master 持有的各设备 `applied_seq` 全表。
- `master.migrate`：请求**本机**执行升主编排（对端发起或本机 loopback）。
  1. 向旧 master 拉 `sync.cursors`；不可达则用本机游标账副本；
  2. **旧 master 可达时**：按设备列表差量 `list`/`read`（payload `seed: true`）拉取他端分区到本机（`MirrorSeedService`）；`seeded_files` 为成功写入数；
  3. **内容哈希门闩**（`MirrorHashGate`）：对比旧 master 与本机 path→sha256；`hash_gate` 摘要写入结果；默认软校验不阻断；调用方可设硬阻断；
  4. 种子合并（只进不退）→ 提升 `epoch` → 写本机 master 指针；
  5. 向各 owner 广播 `master.pointer`；触发同步引擎差量重放。
  - **注意**：旧 master 不可达时只迁移游标，不搬运他端历史 blob；缺口依赖各端正式区后续推送（方案 §6.5）。
  - `seed: true` 仅 owner 可读他端私有分区（attachments/backups）；用于升主种子，不替代导入授权。
  - `list.limit` 可选（默认 1000，上限 50000）；种子/门闩使用上限以免截断假缺口。

### 10.2 指针广播与离线改指

```json
// 通知帧（无 req_id）
{"op": "master.pointer", "master": "<id>", "epoch": 3, "from": "<issuer>"}

{"op": "master.pointer.query"}
→ {"op": "result", "data": {"master": "<id>", "epoch": 3}}
```

- 接收方仅当 `epoch` ≥ 本地 epoch 时改指并 `syncNow`。
- 任意 owner 上线时，客户端先 `master.pointer.query` 再决定是否改指，
  然后若对端是当前 master 则差量重放（离线端醒来正确改指）。

### 10.3 镜像树再保护（§6.6）

master 定期（与日快照同节奏）或迁移后：将各 `<device_id>/<space>/` 打 tar，
主密码派生密钥加密，经 store commit 写入 `<master_id>/backups/reprotect-<ts>/`
（`manifest.json` + `mirror.tar.enc`）。

## 11. 本地优先与 loopback（M2 边界）

- M2 的 master 默认本机：客户端调用与 master 处理走同一代码路径（loopback dispatch），无网络往返。
- master 为他端时，请求经 peer 控制帧发送并等待 `result`（超时 15s 返回 `master_offline`）。
- CAS、未同步队列、变更游标、批量原子上传在 M4 落地（本文件 §6/§7）；master 迁移在 M6（本文件 §10）。
- 远程访问复用 channel tunnel：`store.*` 帧经 PeerConnectionManager 的
  local→channel 回退链路透明传输，协议无感知。

## 12. 版本与兼容

- `v=4`（本文档 store.*）。新增 op 或必填字段 ⇒ `v+1`；只增可选字段不变版本。
- v3 → v4：新增 `sync.cursors` / `master.pointer` / `master.pointer.query` /
  `master.migrate`。v3 客户端忽略未知 op 通知，互操作不受影响。
- Go 节点（M7，`storage-node/`）与本规范对齐；攻击 fixture 与 ACL fixture 双端共享
  （`docs/storage_fixtures/`）。

## 13. memory.* / she.*（M8，独立控制帧 type）

与 `store` 并列的 peer 控制帧命名空间（`type`/`ns` = `memory` 或 `she`），
仅接受 **owner** 级配对；friend 一律拒绝（与 store 一致）。

### 13.1 she.presence — 能力画像（类别级 + 可选名单）

```json
{"type":"she","ns":"she","op":"presence",
 "device":"<id>","she_name":"办公室的她","online":true,
 "agent_categories":["she","assistant"],
 "tool_categories":["filesystem","web","shell"],
 "agent_count":2,
 "agents":[{"id":"<agent_id>","name":"She","category":"she"}],
 "updated_at":1721300000000}

{"type":"she","ns":"she","op":"presence.query"}
```

- 默认只广播**类别与数量**；用户开启分享名单后附带 `agents[]`（owner 级可见；friend 仍拒绝整帧）。
- 委托路由：`routeByCategory` / `routeByAgentId`；点名复用现有 peer agent 审批链路。

### 13.2 memory.digest.offer — 蒸馏摘要交换

```json
{"type":"memory","ns":"memory","op":"digest.offer",
 "from_device":"pc-b","period":"2026-07-20/2026-07-26",
 "entries":[{"kind":"preference|ongoing|fact","text":"...","confidence":0.8}]}

{"type":"memory","ns":"memory","op":"digest.ack","accepted":2,"from_device":"..."}
```

- 原始记忆不出机；落库 `external_memories`（来源隔离、追加式）。
- 触发：owner 连接后低频自动（每日至多一次）+ 手动；总开关 + 类别开关（关闭类别不出机/不入库）。

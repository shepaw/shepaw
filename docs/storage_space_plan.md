# 存储空间方案：设备目录镜像 + 统一 store.* 协议

> 状态：**v1.0 定稿**（经 v1~v16 十六轮迭代，所有架构与产品决策已确认，进入实施阶段）
> 协议契约：`docs/storage_protocol_spec.md`（M2 前编写）；旧 `sync_protocol_spec.md`（v4 模型）已废止。
> 定位依据：每端 app 产生的所有数据（DB 快照、附件、产物、文件）都放在自己的 `<device_id>/` 目录下，统一先写本地；同步引擎只负责把 `<device_id>/*` 镜像到 master；跨端协作通过读其他端目录中开放的分区实现。数据不出用户自己的硬件。

## 1. 目标与非目标

**目标**
- **存储空间体系完全独立**：自成一套模块，不拥有、不依赖设备配对流程的生命周期；只消费配对结果（设备列表、信任等级、加密通道）。
- **统一的设备目录模型**：每端 app 产生的所有实体数据都放在 `<device_id>/` 下（实体文件不进 DB，DB 快照也是目录里的文件）；**写入永远先落本地**，同步引擎只负责把 `<device_id>/*` 镜像到 master——没有独立的备份协议与离线策略，它们都是镜像模型的自然结果。
- **写权限收敛**：任何端只能写自己的 `<device_id>/`，跨目录写在机制上不可能。
- **跨端协作**：`<device_id>/artifacts` 与 `<device_id>/files` 对所有 owner 端可读——不同端的 Agent 通过产物 URI 感知并引用彼此输出。
- **私有数据受保护**：`<device_id>/backups`（加密快照）与 `<device_id>/attachments` 仅本端可读写。
- **变更游标**：每端为自己的目录维护单调递增的变更游标，用于镜像对账与 master 迁移（6.4/6.5）。
- 设备身份跨重装保持稳定；换机经导入授权读取旧设备目录（5.4）。
- 每台设备的 she 是独立个体，组成多 she 网络（第 8 节）。

**非目标（明确不做）**
- **不做 app 状态数据的多端融合**：各端 DB 独立，永不合并（v4 模型废弃）；跨端共享的是文件，不是数据库。
- **不做多主**：唯一 master 作为镜像汇聚点与跨端读取权威；写冲突 last-write-wins（以 master 接收顺序为准）。
- 不做共享文件的自动保留期——**删除由用户在 UI 手动操作**（决策 1）。
- **master 故障不做自动 failover**——手动指定/迁移（决策 2）。
- 不做账号体系、云端中继、陌生人 P2P 互助备份；不做跨人 she 社交（预留 `trust_level`，8.3）。
- 记忆交换只交换蒸馏摘要；私有分区原始数据不出本端信任域（快照加密后例外）。
- 不用 Rust；不在 App 端内 FFI 嵌入原生存储库。
- 实时控制另一台设备的 Agent 走现有 peer agent 通道，不做改动。

## 2. 模型：设备目录 + 镜像同步 + 三层分离

**目录布局（每端本地与 master 同构）**：

```
<device_id>/
├── backups/<snapshot-ts>/    # DB 快照 + 身份（加密，仅本端可读写）
├── attachments/<hash>        # 聊天附件，hash 去重（仅本端可读写）
├── artifacts/<task_id>/...   # Agent 产物（本端写，所有 owner 端可读）
└── files/...                 # 用户文件（本端写，所有 owner 端可读）
.recycle/                     # 回收站（系统目录，可还原，仅 master 本机用户可清空）
```

| 目录 | 写 | 读 |
|------|----|----|
| `<device_id>/artifacts/` | 仅本端 | 所有 owner 端 |
| `<device_id>/files/` | 仅本端 | 所有 owner 端 |
| `<device_id>/attachments/` | 仅本端 | **仅本端**（换机导入授权除外） |
| `<device_id>/backups/` | 仅本端 | **仅本端**（换机导入授权除外） |

- **同步引擎的唯一职责**：把本端 `<device_id>/*` 的变更镜像到 master（本地优先：先写本地，后台送达）。
- **备份策略坍缩**：定期任务在本地生成 DB 快照写入 `<device_id>/backups/<ts>/` 并 `commit`，同步引擎自然送达 master——备份就是镜像，没有第二套机制。
- **master 的角色**：镜像汇聚点 + 跨端读取的权威副本。本地优先意味着 master 故障的损失有限——各端本地都有全量自有数据。

**三层分离**不变：

| 层 | 职责 | 通道 | 本方案动作 |
|----|------|------|-----------|
| 存储层 | 设备目录镜像 + 跨端读取 | `store.*` 帧 | 本方案 |
| 控制层 | 实时互操作、审批工作流 | 现有 peer agent 通道 | **不变，一行不改** |
| 身份层 | 多 she 网络、记忆交换 | `memory.*` / `she.*` 帧 | 第 8 节 |

**模块边界**：配对流程完全属于 peer 层；存储层只读取配对结果（`paired_peers`、`trust_level`、Noise 通道）。未配对设备单机完整可用（镜像队列等待 master 出现）。

## 3. 复用现有资产

| 能力 | 现有实现 | 复用方式 |
|------|---------|---------|
| E2E 加密会话 | `lib/peer/services/peer_connection.dart`（WS + Noise） | `store.*` / `memory.*` 帧的传输与身份识别 |
| 局域网服务 | `lib/peer/services/peer_local_server.dart`（端口 18792） | master 常驻监听 |
| 远程隧道 | `channel_tunnel_service.dart`、`peer_channel_bridge.dart` | 异地访问走隧道，协议不变 |
| 设备配对 | QR 配对 + `paired_peers` 表 | 存储层只读消费；预留 `trust_level` 字段（owner / friend） |
| 存储 | `LocalStorageService` + DAO 层 | 私有域新增外部记忆表，业务表零改动 |
| 附件 | `attachment_service`、`local_file_storage_service` | 附件改走 store（产品未上线，直接按新模型实现，无存量迁移负担） |
| 导出 | `data_export_import_service.dart` | 快照序列化/加密的实现基础 |
| 群组编排 | `lib/services/group/`（orchestration / planning / flow） | 跨端工作流中注入产物引用（6.3） |
| Go 协议层 | agent-bridge（Go 实现的 peer/Noise 接入） | 抽共享 protocol package，供 Go 节点复用 |

## 4. 配对信任分级（预留字段）

`paired_peers` 新增 `trust_level TEXT`（`owner` | `friend`），本期即落字段与协议校验：

- `owner`（自己的设备）：开放存储空间访问（按第 2 节 ACL）、记忆交换、执行委托。
- `friend`（他人的设备，为跨人社交预留）：仅受监督对话；`store.*` / `memory.*` 帧一律拒绝并记录审计日志。

## 5. 私有域：快照、恢复与设备身份

### 5.1 快照生成与送达

- 定期任务（默认 daily，GFS 保留 7 日/4 周/12 月——决策 4 确认）在本地生成快照，写入 `<device_id>/backups/<ts>/` 并 `commit`；同步引擎随后送达 master，master 对该目录执行 GFS 清理。
- 无 master 时快照天然留存本地（本地优先的必然结果）。
- **兜底导出**（决策 3）：本机目录 / WebDAV 降级为**纯手动导出功能**，不占任何自动路径；格式相同（附件随导出打包）。
- iOS 后台受限，实际触发点为"App 打开时 + 充电/WiFi 系统后台任务兜底"；连续失败 ≥3 天显著告警。

### 5.2 快照格式

```
<device_id>/backups/<ts>/
├── manifest.json     # device_id, created_at, app_version, schema_version,
│                     # db_sha256, attachments: [hash...], 完整哈希树
├── db.sqlite.enc     # VACUUM INTO 一致性快照，整体加密
└── identity.enc      # 设备身份（Noise 密钥对），随快照加密
```

- 附件不进快照：按 hash 引用 `<device_id>/attachments/`，恢复后惰性拉回；手动导出仍打包全量附件。
- 加密：XChaCha20-Poly1305，密钥 = KDF(主密码, 设备 salt)；**离开本机前必须已加密**。
- **主密码变更**：改密后自动生成新密钥全量快照；旧快照标注"需旧密码恢复"。

### 5.3 恢复

管理页或 onboarding 换机入口 → `store.list(backups)` → 选快照 → `store.read` 拉回 → 输密码解密 → 校验 manifest 哈希树 → **先自动留存本机安全快照** → 全量替换 → 重启生效。恢复是全量替换、不合并，界面明确告知。

### 5.4 设备身份与换机导入授权

- **device_id 跨重装不变**：设备身份（Noise 密钥对，device_id 为其公钥哈希）随加密快照保存；重装后从快照恢复即恢复原 device_id。**全新安装且不从快照恢复 = 新设备、新 device_id**。
- **换机导入授权**：新设备恢复旧设备数据时，由用户显式选择数据来源设备——
  - **旧设备在场**：新设备扫旧设备二维码，旧设备签发一次性**导入授权**（签名声明：允许 device_id_new 读取 `<旧 id>/backups` 与 `<旧 id>/attachments`）；
  - **旧设备不在场/已丢失**：输入旧 device_id，导入请求出现在 master 管理页，**由用户在 master 侧手动确认**后放行。
- 授权为一次性、限旧设备私有目录只读；新设备此后用自己的 device_id 写自己的目录，**两个 device_id 互不影响**；旧目录保留，用户可在管理页手动删除。
- **附件归属迁移**：恢复的 DB 按 hash 引用旧设备附件；新设备用到时经授权惰性拉回并写入自己的 `<新 id>/attachments/`，逐步完成归属迁移。
- **换机后需重新配对**：新 device_id 对其他端而言是新设备——需与 master 及各端重新配对（旧配对记录手动删除）；she 的数据与记忆随 DB 完整保留。

## 6. store.* 协议与同步引擎

### 6.1 协议（client → master，含 master 本机 loopback）

```json
{"ns": "store", "op": "list",  "space": "artifacts", "device": "pc-b", "path": "task-41/"}
{"ns": "store", "op": "read",  "space": "artifacts", "device": "pc-b", "path": "task-41/x.py", "offset": 0, "length": 65536}
{"ns": "store", "op": "meta",  "space": "artifacts", "device": "pc-b", "path": "task-41/x.py"}
{"ns": "store", "op": "write.begin", "space": "artifacts", "path": "task-41/x.py", "size": 4096, "sha256": "..."}
{"ns": "store", "op": "write.chunk", "space": "artifacts", "path": "task-41/x.py", "offset": 0, "eof": true}
{"ns": "store", "op": "commit", "space": "backups", "path": "snapshot-20260718/", "retention": {...}}
{"ns": "store", "op": "delete", "space": "files", "path": "old.zip"}
{"ns": "store", "op": "stats"}
```

- `space` ∈ `artifacts | files | attachments | backups`，必填单值；**写操作永远落在调用者自己的 `<device_id>/` 下**（跨目录写在机制上不可能）；`device` 参数仅用于读取/列举其他端目录，缺省为调用者。
- 分块 64KB、SHA-256 校验、offset 幂等断点续传。
- **`commit` 原子转正**：一次逻辑写入先落 `<device_id>/<space>/.staging/<upload_id>/`，对 `list`/恢复不可见；`commit` 后整批原子转正；超过 24h 未 commit 的暂存自动清理（决策 4）。
- `meta`：只返回元数据（sha256、size、mtime），不传输内容，用于缓存校验；path 为目录时返回清单及各文件 hash（一次往返完成批量校验）。
- 缓存：**按内容 hash 做缓存键**；LRU 容量上限可配（**默认 500MB**——决策 6）；未同步（未获 master ack）数据不可淘汰。

### 6.2 防串写与回收站

- **写入路径收敛**：写操作的目标目录由协议构造为 `<调用者 device_id>/<space>/`，客户端无从指定他人目录——串写从机制上不可能，master 只需校验"调用者身份 = 目标 device_id"。
- 路径规范化：拒绝绝对路径、`..` 穿越、符号链接逃逸。
- fixture 必须包含攻击用例：伪造 device_id 写入、读取他人私有目录、路径穿越、伪造导入授权。
- **删除与回收站**：共享文件的删除由用户在 UI 手动操作（决策 1，无自动保留期）；`delete` 只移入 `.recycle`（保留 30 天），被覆盖的旧版本同样进 `.recycle`；**回收站支持还原**（决策 4：文件可从 `.recycle` 移回原路径）；**清空回收站仅 master 本机用户**；Agent 的 delete 权限默认关、单独可配。

### 6.3 产物引用与跨端协作

- **统一引用规范**：`store://artifacts/<device_id>/<task_id>/<filename>`。URI 与具体 master 解耦，由 `artifact_service` 解析。
- **引用表达格式**（Agent 间传递的唯一格式）：Markdown 链接 + 一句话描述，单行——

  `[report.md](store://artifacts/pc-b/task-41/report.md) — Q2 销售报告，markdown，12KB（codebot 产出）`

  理由：LLM 原生擅长 Markdown 链接；URI 是唯一机器 token，正则可解析；聊天 UI 直接渲染为可点击附件。
- **Agent 侧纪律**（由编排层注入）：
  - 引用：原样引用 URI，不改写、不拼接路径——Agent 只"转述"URI，从不"构造"URI；
  - 读取：`store_read(uri)` 单参数；分块、缓存、大文件落盘由工具层处理；
  - 写入：`store_write(filename, content)` 返回新 URI，返回即完成共享（本地优先，后台同步）。
- **工作流注入**：群组编排跨端派活时，编排层在任务上下文注入标准片段（改造点在 `lib/services/group/`）：

  ```
  ## 可用产物
  - [report.md](store://artifacts/pc-b/task-41/report.md) — Q2 销售报告，markdown，12KB（上游 codebot 产出）
  读取：store_read 原样传入括号内 URI；产出：store_write 返回新 URI 即完成共享。
  ```

- **统一写入路径**：任何端的 Agent（含 master 本机的 Agent）产出都经 `artifact_service` → `store.*` 写入自己设备目录，无特权路径。
- 用户聊天中可 "@" 引用产物 URI，无本地缓存时自动拉取。

### 6.4 本地优先、同步引擎与变更游标

- **写入路径**：`store.write` 先落本地 `<device_id>/`（内容按 hash 存于本地 CAS，目录树为逻辑视图），返回成功；变更进入未同步队列，同步引擎后台送达 master，ack 后本地副本转为可淘汰缓存。
- **变更游标**：每端为自己的 `<device_id>/` 维护单调递增的**变更游标**（每次 `commit` / 删除 +1），并记录已获 master ack 的游标水位；master 记录每个设备目录已应用的游标。游标仅用于本设备目录的镜像对账，不涉及跨设备排序（区别于 v4 全局序号）。
- **批量原子性**：本地 `commit` 封批 → 整批按序传输，**commit 标记最后送达** → master 侧 staging 转正并推进该设备游标。
- **删除**：本地标记后进队列；master 重放后移入 `.recycle`。
- **读路径（缓存校验流程）**：读取他端数据时先查本地缓存——有缓存则向 master 发 `store.meta` 比对内容 hash：**一致则直接使用缓存（零内容流量）**，不一致则从 master 下载最新并更新缓存；无缓存且 master 在线则直接拉取。master 离线时：有缓存则使用缓存并标注"可能不是最新"，无缓存则报缺。
- **冲突**：last-write-wins（以 master 接收顺序为准），被覆盖旧版本进 `.recycle`。
- **磁盘压力**：未同步数据不可淘汰；管理页展示未同步占用，超阈值告警。
- **master 指针**：迁移后向各 owner 端广播；离线端醒来经任一在线 owner 端获取并验证，同步目标随之切换。

### 6.5 master 指定与游标迁移

- 指定：存储管理页从 owner 级在线设备中选择 master（同一时间唯一）；**推荐 Go 常开节点**（第 9 节）。
- **故障手动处理**（决策 2）：master 失联不做自动 failover，各端本地正常工作，用户择机在管理页迁移。
- **迁移流程（决策 1）**：
  1. 新 master 首先向**旧 master** 请求各设备目录的最新游标；旧 master 不可达，则以自己本地（作为 client 持有的副本）的游标为准；
  2. 各端收到指针广播后向新 master 报到，比对游标：本地比新 master 新的部分（含未同步队列）**按游标差量重放**；
  3. 冲突 last-write-wins，被覆盖版本进 `.recycle`；
  4. 逐设备校验哈希一致后指针正式生效，旧 master 降级为普通端。
- 游标让迁移从"全量重建"变成"差量重放"，且全程可对账。

### 6.6 master 数据的再保护

master 上的镜像树主要是各端本地数据的副本；为防止各端本地缓存淘汰后的数据损失，master 定期对整棵镜像树做加密快照（写入自己的 `<master_id>/backups/` 或手动导出介质）。

## 7. 存储空间管理页（独立体系）

入口：设置 → 存储空间。本页是存储体系的唯一管理面，与配对流程无关。

1. **本机存储卡片**：本机目录大小、未同步条数与占用、变更游标水位、本地安全快照。
2. **备份与恢复**：快照列表（GFS 状态）、立即快照、恢复、**换机导入**（扫码 / 输入 device_id）、旧设备目录手动删除。
3. **存储空间**：当前 master 及用量（80% 告警，不设单设备硬配额——决策 6）、指定/迁移 master、按设备/分区浏览文件、文件手动删除、回收站（**支持还原**；清空仅 master 本机）、导入授权审批。
4. **她的朋友圈**：每个配对 she 一行——名字、信任等级、最近交换时间、类别开关、手动触发。
5. **危险区**：删除本机数据、**手动导出**（本机目录 / WebDAV）。

## 8. 身份层：多 she 网络与记忆交换（决策）

### 8.1 决策

- 每台设备的 she 是**独立个体**，身份绑定设备场景；多台 PC / 手机各自持有独立的她，组成多 she 网络。"双 she"只是 N=2 的特例。
- 能力边界清晰：每个 she 只管理本机 Agent；需要对方设备能力时通过 peer 通道**与对方 she 对话委托**（复用现有 peer agent / 审批链路）。
- **命名**：多台设备时用户可为每台的她起名（默认按设备场景）。
- **委托路由**：`she.presence` 帧广播能力画像——**只广播类别**（决策 5：Agent 类别与数量、工具类别、在线状态），不暴露具体 Agent 名单；委托方据此选择问谁，用户可显式点名；粒度不足时再升级为名单级。
- 跨端协作走**可寻址的产物文件**（读其他端 `artifacts` 目录），而不是私有数据的融合。

### 8.2 记忆交换

- 只交换**蒸馏摘要**（偏好变化、进行中的事项、重要事实），原始数据不出机；`memory.*` 帧仅接受 owner 级设备：

```json
{"ns": "memory", "op": "digest.offer", "from_device": "pc-b",
 "period": "2026-07-11/2026-07-18",
 "entries": [{"kind": "preference|ongoing|fact", "text": "...", "confidence": 0.8}]}
```

- 触发：owner 级设备连接后低频自动（每日至多一次——决策 4）+ 手动触发。
- 落库：`external_memories` 表，标注来源设备与时间，按来源隔离、追加式、无合并冲突；she 可引用"办公室的她告诉我……"。
- 用户控制：总开关 + 类别级开关；摘要由本机 she 生成（复用 `she_service`），只发允许类别。

### 8.3 前瞻：跨人 she 社交（预留兼容，本期不做）

- 信任分级已就位（第 4 节）：friend 级无存储空间访问权、无记忆交换权、无执行委托权。
- 分享受主人控制："名片/动态"形式由我审批；敏感请求走现有 SAFE/WARNING/DANGEROUS 权限门。
- 协议隔离：`she.social.*` 独立命名空间。
- 已知硬骨头——异步送达：纯 P2P 需双方同时在线；加密信箱哑中继与"无服务端"原则有张力，届时再权衡。

## 9. Go 存储节点（M7，时机保持——决策 3）

常开 Linux / NAS / 旧主机上的无头节点，职责单一：**master 的最佳人选**。

- 常开特性让未同步队列与快照送达不受 PC 休眠影响。
- 技术：Go；`nhooyr.io/websocket` + `flynn/noise`（与 agent-bridge 共享 protocol 包）；实现 `store.*` 全量语义与 ACL；不需要 SQLite。
- 无屏幕配对：一次性配对码 / Web 管理页。
- 协议一致性：与 Dart 实现共用 `docs/storage_protocol_spec.md`（版本化）和共享 fixture（含 6.2 攻击用例）。

## 10. 安全

- 私有快照离开本机前已加密（主密码派生密钥）；master 与其他端均不可见明文。
- 附件与共享文件：传输经 Noise 加密；master 上静态加密依赖设备 OS（owner 信任域内）；镜像树再保护副本经 6.6 链路加密。
- 信任分级强制执行：`store.*` / `memory.*` / 执行委托帧只接受 owner 级设备；friend 级越权帧拒绝并审计。
- 写入路径收敛（6.2）+ Noise 身份校验，串写从机制上不可能；换机导入授权需旧设备签名或 master 侧用户确认（5.4）。
- 主密码遗忘 = 快照无法解密：开启时强制验密 + 管理页解密自检。

## 11. 分阶段实施

| 阶段 | 内容 | 验收标准 |
|------|------|---------|
| M1 快照引擎 | 5.2 快照格式（含 identity.enc）+ 加密 + manifest 校验 + 本机导出 | 本机生成快照并恢复，数据与 device_id 完整；篡改被哈希校验发现 |
| M2 空间与协议 | `trust_level` + 6.1 `store.*`（含 meta/commit）+ 6.2 写路径收敛与回收站还原 + master loopback 入口 | 所有端经 store.* 读写；半成品不可见；攻击 fixture 全绿；friend 级帧被拒；回收站可还原、清空仅 master |
| M3 快照与恢复 | 5.1 定期快照 + GFS + 5.3 恢复 + 5.4 换机导入授权 + 密码变更策略 | 本机每日快照经 store write/commit 落盘（GFS 清理）；master 为本机时快照即落盘；**远端 master 送达依赖 M4 同步引擎**。路径 A：扫码/粘贴旧设备 peer QR（未配对则先配对）或手输 device_id → 授权导入；路径 B（master 侧镜像）依赖 M4。改密后新旧快照各用其钥 |
| M4 本地优先与远程 | 6.4 同步引擎（CAS + 未同步队列 + 变更游标 + 批量原子上传）+ channel tunnel 远程 | 无 master 时本地完整可用；master 上线后镜像一致、游标水位对齐、commit 标记最后送达；4G 下可读写 |
| M5 协作与附件收口 | 6.3 产物 URI + `artifact_service` + 工作流注入 + 附件直接按新模型经 store 存取 | 跨端工作流下游 Agent 凭 URI 读上游产物；附件统一经 store；快照只含 DB 与身份 |
| M6 master 迁移 | 6.5 游标迁移流程 + 指针广播 + 6.6 再保护 | 旧 master 可达/不可达两种路径下，各端按游标差量重放后镜像树一致；离线端醒来正确改指 |
| M7 Go 存储节点 | 第 9 节 + 协议一致性 fixture | Go 节点胜任 master；与 Dart 实现 fixture 全绿；7×24 运行 |
| M8 记忆交换与多 she | 8.1 命名 + `she.presence`（类别级）+ 8.2 `memory.*` + 类别开关 | 两设备互引摘要；三设备组网委托路由正确；关闭类别后摘要不出机 |

Dart 侧新增代码集中在 `lib/storage/`（snapshot_service、store_protocol、local_cas、sync_engine、artifact_service、restore_service、device_identity）与 `lib/she_network/`（digest_service、external_memory_store、presence_service），页面为 `lib/screens/storage_space_screen.dart`，`lib/peer/` 只加帧路由，业务逻辑零侵入。

## 12. 主要风险与对策

- **跨端读到脏数据**：他端目录的本地副本即权威源——master 只是镜像；读取经 hash 校验，脏数据可被发现并从他端重新拉取。
- **master 长离线**：未同步数据膨胀——管理页展示占用并告警；根治靠 Go 常开节点（M7）。
- **重装丢身份**：全新安装=新 device_id，旧目录需经 5.4 授权导入；开启快照时提示"身份随快照保存，重装后请先恢复"。
- **写冲突**：last-write-wins 可能覆盖——回收站 30 天且支持还原；产物按 task_id 归档天然避免撞名。
- **恢复覆盖风险**：恢复前强制安全快照 + 界面明确替换语义。
- **快照静默失败**：连续失败 ≥3 天显著告警，引导启用常开节点。
- **master 磁盘膨胀**：无自动保留期（决策 1）——80% 用量告警 + UI 手动删除 + 回收站 30 天；GFS 仅作用于 backups。
- **密码遗忘/变更**：强制验密 + 解密自检；改密自动重加密新快照、旧快照支持历史密码。
- **多 she 记忆分叉**：记忆交换 + 来源标注缓解；叙事为"一个主力设备上的她"；产物互通走目录读取。

## 13. 后续可选（不承诺）

- 快照差量化（页面级 diff）。
- 回收站增强（保留 N 版、按目录清理）。
- `she.presence` 升级为名单级广播（委托路由精度不足时）。
- 在线控制场景深化（peer agent 通道，独立立项）。
- 跨人 she 社交：前置条件已在 8.3 预留，异步送达方案届时再定。
- DB 级多端互通：若未来确需，参考 v4 草案另行设计，不在本方案内。

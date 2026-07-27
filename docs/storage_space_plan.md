# 存储空间方案：设备目录镜像 + 统一 store.* 协议

> 状态：**v1.1（与实现对齐）** — 相对 v1.0 消解权威模型矛盾，按 `lib/storage/` 实装修订 CAS / GFS / 迁移语义；M1–M8 已落地（M7 含 Noise 配对与无头管理面）。
> 协议契约：`docs/storage_protocol_spec.md`（权威）；旧 `sync_protocol_spec.md`（v4 模型）已废止。
> 定位依据：每端 app 产生的所有数据（DB 快照、附件、产物、文件）都放在自己的 `<device_id>/` 目录下，统一先写本地；同步引擎只负责把 `<device_id>/*` 镜像到 master；跨端协作通过读其他端目录中开放的分区实现。数据不出用户自己的硬件。
>
> **权威模型（定稿，与代码一致）**
>
> | 角色 | 权威范围 | 说明 |
> |------|----------|------|
> | 各端本地 `<device_id>/` | **写权威** | 写入永远先落本机正式区（真实文件树）；未同步队列保障送达 |
> | 当前 master 上的镜像 | **跨端读权威** | 他端 `artifacts`/`files` 一律经 master `meta`/`read`；本地仅作读缓存 |
> | 源设备本机目录 | 写权威；跨端读回退 | 默认跨端读走 master；master `not_found`/离线无缓存时直读源设备 |
>
> 耐久性含义：未获 master ack 的数据以本机为准且不可丢；**已 ack 数据的跨端可读性绑定 master**。本机正式区默认保留自有数据（不因 ack 自动淘汰）；远端读缓存可 LRU 淘汰。

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
- **不做多主**：唯一 master 作为镜像汇聚点与跨端读取权威。单写者目录下几乎无并发写冲突；覆盖语义以 master 接收/重放顺序为准（被覆盖旧版进 `.recycle`）。
- 不做共享文件的自动保留期——**删除由用户在 UI 手动操作**（决策 1）。
- **master 故障不做自动 failover**——手动指定/迁移（决策 2）；接受「无常开节点时跨端读不可用」。
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
- **master 的角色**：镜像汇聚点 + **跨端读取权威**。master 故障时：各端**自有正式区仍完整可用**；跨端读仅能用本地读缓存（`stale`）或报缺——不宣称「跨端协作在 master 离线时仍完整」。

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
| Go 存储节点 | `storage-node/`（骨架） | M7：协议/目录树已有；Noise 配对与无头管理面待补 |

## 4. 配对信任分级（预留字段）

`paired_peers` 新增 `trust_level TEXT`（`owner` | `friend`），本期即落字段与协议校验：

- `owner`（自己的设备）：开放存储空间访问（按第 2 节 ACL）、记忆交换、执行委托。
- `friend`（他人的设备，为跨人社交预留）：仅受监督对话；`store.*` / `memory.*` 帧一律拒绝并记录审计日志。

## 5. 私有域：快照、恢复与设备身份

### 5.1 快照生成与送达

- 定期任务（默认 daily，GFS 保留 7 日/4 周/12 月——决策 4 确认）在本地生成快照，写入 `<device_id>/backups/<ts>/` 并 `commit`；同步引擎随后送达 master。
- **GFS 在快照所属设备本机执行**（`ScheduledSnapshotService` + `commit.retention`/`selectGfs`），删除经同步队列镜像到 master——**不是** master 代管剪枝。`commit.retention` 支持 `keep_last` / `gfs`（见协议 §2.6）。
- 无 master 时快照天然留存本地（本地优先的必然结果）。
- 兜底导出（决策 3）：本机目录 / WebDAV 降级为**纯手动导出功能**，不占任何自动路径；格式相同（**附件随导出打包**：`exportToDirectory` 按 manifest 复制到 `attachments/`）。
- 移动端触发：App 启动 + 运行中 6h Timer + **回前台**（`AppLifecycleService.onResume`）+ **WiFi/以太网稳定**（`NetworkMonitorService.onNetworkSettled`，避免蜂窝灌库）。系统级 BGAppRefresh / WorkManager 仍为后续可选（`ForegroundTaskService` 仅 Agent 保活，不接入日快照）。距上次成功（或从未成功则距启用）超过 **3 天** 显著告警（按墙钟，非同日失败次数）。

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
  - **旧设备在场**：新设备扫旧设备二维码，旧设备签发一次性**导入授权**（签名声明：允许 device_id_new 读取 `<旧 id>/backups` 与 `<旧 id>/attachments`）；旧设备收到 `import.request` 时发**系统通知**（`ImportRequestNotifier`），点击打开存储页审批；新设备收到 `import.grant` 推送时同样通知（`ImportGrantNotifier`），可立即浏览导入；
  - **旧设备不在场/已丢失**：输入旧 device_id，导入请求出现在 master 管理页，**由用户在 master 侧手动确认**后放行（master 同样收请求通知；新设备收授权通知）。
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
- 分块 64KB、SHA-256 校验、offset 幂等断点续传（内容经 base64 封装在控制帧内；大文件成本已知，后续可换二进制帧）。
- **`commit` 原子转正**：一次逻辑写入先落 `<device_id>/<space>/.staging/<upload_id>/`，对 `list`/恢复不可见；`commit` 后整批原子转正；超过 24h 未 commit 的暂存自动清理（决策 4）。
- `meta`：只返回元数据（sha256、size、mtime），不传输内容，用于缓存校验；path 为目录时返回清单及各文件 hash（一次往返完成批量校验）。
- **远端读缓存**（非本地写路径）：按内容 hash 键入 `LocalCas`（默认 LRU **500MB**——决策 6）；仅服务于他端共享区读取。本机正式区是真实文件树，不经 CAS 写入。

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

- **写入路径**：`store.write` / `commit` / `delete` 先落本机 `<device_id>/` **真实文件树**（`LocalStore`），返回成功；变更由 `LocalStore` 内联写入 `SyncJournal`，`SyncEngine` 后台送达 master。本机为 master 时 loopback 直接推进水位出队。
- **变更游标**：每端为自己的 `<device_id>/` 维护单调递增的 `change_seq`（每次 commit/删除 +1）与已获 ack 的 `ack_seq`；master 侧 `DeviceCursorStore` 记录各设备 `applied_seq`。游标仅用于本设备目录镜像对账，不涉及跨设备排序。
- **批量原子性**：按 seq 上传（write.begin/chunk），**commit 标记最后送达**并带 `upto_seq` → master 转正后推进 `applied_seq` → 客户端据此出队。
- **删除**：本地移入 `.recycle` 后入队；master 重放后同样入 `.recycle`。
- **读路径（跨端共享区）**：`RemoteReadService` 向 **当前 master** 发 `store.meta` / `store.read`——有缓存则比对 hash（一致零内容流量）；不一致或无缓存则下载并写入 `LocalCas` + `.cache`；master 离线有缓存则 `stale: true`。`not_found` 有限重试后仍失败，或 master 离线且无缓存时，**向源设备直读回退**（`fromOwnerFallback`）。
- **覆盖语义**：同路径后写覆盖先写（以 master 接收/重放顺序为准），旧版本进 `.recycle`。单写者目录下正常无多端争用；竞态主要出现在迁移窗口或同设备重复投递。
- **磁盘压力**：未同步队列占用由管理页展示；默认 **未同步 ≥200MB** 告警。master（本机 store 所在卷）用量经 `stats.volume_*` 探测，**≥80%** 显著告警（`VolumeUsage`）。
- **master 指针**：迁移后向各 owner 广播；离线端醒来经 `master.pointer.query` 获取并按 epoch 改指，再 `syncNow`。

### 6.5 master 指定与游标迁移

- 指定：存储管理页从 owner 级在线设备中选择 master（同一时间唯一）；**推荐常开节点**（第 9 节）。
- **故障手动处理**（决策 2）：master 失联不做自动 failover，各端本地正常工作，跨端读降级；用户择机在管理页迁移。
- **迁移流程（与 `MasterMigrationService` 一致）**：
  1. 新 master 向旧 master 请求 `sync.cursors`；不可达则以本机游标账副本为准；
  2. **旧 master 可达时**：按游标/stats 设备列表，经 `list`/`read`（`seed: true`）差量拉取他端分区到本机（`MirrorSeedService`）；不可达则跳过（缺口风险见下）；
  3. **内容哈希门闩**（`MirrorHashGate`，软校验）：种子后对比旧 master 与本机各设备 path→sha256；差异写入 `MigrationResult.hashGate`，**默认不阻断**升主；`requireHashMatch: true` 可硬阻断；
  4. 游标种子合并（只进不退）→ bump `epoch` → 写本机 master 指针；
  5. 向各 owner 广播 `master.pointer`；各端改指后把**本地比新 master 新的差量**（含未同步队列）`syncNow` 推送；
  6. 可选触发镜像再保护（§6.6）。
- **明确接受的缺口（旧 master 不可达时）**：升主只迁移**游标账**，不自动搬运他端历史 blob。新 master 上缺失的他端历史数据，依赖各端仍持有正式区并随后推送；若某端已丢本地且旧 master 不可达，该段镜像可能永久缺口。产品上应在升主 UI 提示此风险。

### 6.6 master 数据的再保护

master 上的镜像树主要是各端本地数据的副本；为降低单点损坏风险，master 定期（或迁移后）对整棵镜像树做加密快照（`MirrorReprotectService` → `<master_id>/backups/reprotect-<ts>/`）。无缓存主密码时跳过。

**保留策略**（与 DB 快照 GFS 分离）：成功写入后只保留最新 **4** 份（`defaultMaxKeep`），更早的经 `delete` 进 `.recycle`。

## 7. 存储空间管理页（独立体系）

入口：设置 → 存储空间。本页是存储体系的唯一管理面，与配对流程无关。

1. **本机存储卡片**：本机目录大小、未同步条数与占用（≥200MB 告警）、变更游标水位、本地安全快照。
2. **备份与恢复**：快照列表（GFS 状态）、立即快照、恢复、**换机导入**（扫码 / 输入 device_id）。
3. **存储空间**：当前 master 及用量（卷剩余 / **≥80% 告警**）、指定/迁移 master（升主时提示旧 master 不可达的数据缺口风险）、**他端镜像目录手删**（`LocalStore.purgeDevice`，仅 master 本机、禁删自身、同步清游标）、**按设备/分区浏览与手删**（`StorageBrowserScreen`，本地 list；本机可删自身，master 可删他端镜像进回收站）、回收站（**支持还原**并有结果提示；**清空仅 master 本机**显示与执行；列表可展开超过 20 条）、导入授权审批。
4. **她的朋友圈**：每个配对 she 一行——名字、信任等级、最近交换时间、类别开关、手动触发（实现位于 `lib/she_network/`，管理入口同页，逻辑与存储解耦）。
5. **危险区**：本机 store 树**手动导出**（`StoreExportService`）；**WebDAV 兜底导出**（`StoreWebdavExportService`，MKCOL+PUT，凭据不落盘）；**删除本机存储数据**（`StoreWipeService`，需输入 `DELETE`；清队列保留 change_seq；不删他端镜像 / 回收站 / DB / 身份）。

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

## 9. Go 存储节点（M7，骨架已有）

常开 Linux / NAS / 旧主机上的无头节点，职责单一：**master 的最佳人选**。

- 常开特性让未同步队列与快照送达不受 PC 休眠影响。
- 技术：Go（本仓库 `storage-node/`）；协议与 ACL 与 Dart 共用规范。**Noise IK + `/peer/ws` 配对/重连**已接入（与 App 同 suite/prologue）；提供 loopback HTTP JSON、本机目录树、**`/admin` 无头管理面**。
- **管理面必须与无头形态匹配**：回收站清空、导入授权审批、升主/用量不能只假设 App 本机 UI。M7 已提供受控 **`/admin` Web 页 + REST**（**Noise 配对 / 已配对重连** / **分区浏览手删** / **他端镜像手删** / **本机 wipeSelf** / 用量 / 回收站 / 换机导入审批；`-admin-token` 或 loopback 鉴权）。配对 QR / `PairingResponse` 可带 **`-channel` / `SHEPAW_CHANNEL_ENDPOINT`** 外网端点。
- 协议一致性：与 Dart 实现共享攻击/ACL fixture，双端测试全绿（含升主 `seed: true` 读他端私有分区）。

## 10. 安全

- 私有快照离开本机前已加密（主密码派生密钥）；master 与其他端均不可见明文。
- 附件与共享文件：传输经 Noise 加密；master 上静态加密依赖设备 OS（owner 信任域内）；镜像树再保护副本经 6.6 链路加密。
- 信任分级强制执行：`store.*` / `memory.*` / 执行委托帧只接受 owner 级设备；friend 级越权帧拒绝并审计。
- 写入路径收敛（6.2）+ Noise 身份校验，串写从机制上不可能；换机导入授权需旧设备签名或 master 侧用户确认（5.4）。
- 主密码遗忘 = 快照无法解密：开启自动快照时强制验密（`checkDecryptAndCache`）+ 管理页「解密自检」入口。

## 11. 分阶段实施（状态随代码）

| 阶段 | 状态 | 内容与验收 |
|------|------|-----------|
| M1 快照引擎 | ✅ | `SnapshotService`/`SnapshotCrypto`：格式含 identity.enc、加密、manifest、本机导出/恢复 |
| M2 空间与协议 | ✅ | `store.*` + ACL + staging/commit + 回收站还原；friend 拒绝；loopback |
| M3 快照与恢复 | ✅ 基本 | 定期快照 + 本机 GFS + 恢复 + 换机导入 + 改密；回前台 / WiFi 稳定触发已接；系统 BG 任务仍可选 |
| M4 本地优先与远程 | ✅ 基本 | `SyncJournal`/`SyncEngine` + 游标；`LocalCas` 仅远端读缓存；tunnel 复用 peer |
| M5 协作与附件 | ✅ 基本 | `ArtifactService` URI + 编排注入；附件经 store hash 编址 |
| M6 master 迁移 | ✅ 基本 | 升主/指针/再保护；差量镜像种子 + 内容哈希门闩（软校验，可选硬阻断） |
| M7 Go 存储节点 | ✅ 基本 | `storage-node/`：目录树+fixture；import/retention；**Noise IK `/peer/ws` 配对+重连+Channel QR**；**无头 `/admin`（browse/purge/wipe）** |
| M8 记忆交换与多 she | ✅ 基本 | `lib/she_network/` + 管理页「她的圈子」 |

代码位置：`lib/storage/`、`lib/she_network/`、`lib/screens/storage_space_screen.dart`；`lib/peer/` 仅帧路由。

## 12. 主要风险与对策

- **跨端读滞后 / 脏缓存**：跨端读权威是 **master 镜像**；经 `meta` hash 校验发现不一致则重下。master 损坏或未镜像时，先 `not_found` 重试，再 **owner 直读回退**。
- **master 长离线**：自有数据本地可用；跨端读仅 stale 缓存或报缺；未同步队列膨胀——管理页 ≥200MB 告警；根治靠常开节点（M7）。
- **旧 master 不可达时升主**：只种子游标，他端历史 blob 可能缺口——升主 UI 必须提示；尽量在旧 master 仍在线时迁移。
- **重装丢身份**：全新安装=新 device_id，旧目录需经 5.4 授权导入；开启快照时提示「身份随快照保存，重装后请先恢复」。
- **同路径覆盖**：后写覆盖先写，旧版进回收站 30 天可还原；产物按 task_id 归档降低撞名。
- **恢复覆盖风险**：恢复前强制安全快照 + 界面明确替换语义。
- **快照静默失败**：距上次成功（或从未成功则距启用）超过 3 天且已缓存密钥 → 显著告警（`ScheduledSnapshotStatus.needsAttention`），引导检查存储或手动快照；常开节点（M7）降低漏跑风险。
- **master 磁盘膨胀**：无自动保留期（决策 1）——手删 + 回收站 30 天；GFS 仅本机 DB `backups`（不含 `reprotect-*` 再保护包）；**卷用量 ≥80%** 告警（`stats.volume_warn`）。
- **再保护与 DB 快照隔离**：`listSnapshots` / GFS 跳过 `reprotect-*`；再保护打包时也不再打入既有 `reprotect-*`；写入后 **只保留最新 4 份**（`pruneReprotect`）。
- **密码遗忘/变更**：强制验密 + 解密自检；改密自动重加密新快照、旧快照支持历史密码。
- **多 she 记忆分叉**：记忆交换 + 来源标注缓解；产物互通走目录读取。
- **URI 先于镜像**：编排层传入产物 URI 时文件可能尚未 sync 到 master——`RemoteReadService` 对 `not_found` 做有限退避重试；写入方为本地优先（`ArtifactService` / 附件经 `LocalStore` + 同步队列）。

## 13. 后续可选（不承诺）

- 快照差量化；`she.presence` 名单级；跨人 she 社交；DB 级多端互通（另案）。
- 系统级 BGAppRefresh / WorkManager（日快照已有回前台 + WiFi 触发）。

## 附录 A. v1.1 相对 v1.0 的修订摘要

1. 权威模型写死：写=本机目录，跨端读=master；删除「他端本地副本即权威」。
2. CAS 降级为远端读缓存；本地写为真实文件树 + SyncJournal。
3. GFS 改为各端本机执行，经 sync 镜像删除。
4. 迁移去掉「哈希一致才改指」；写明旧 master 不可达时的 blob 缺口。
5. 告警阈值对齐实现（未同步 200MB）；卷用量 ≥80% 告警见附录 A.10。
6. M7 补无头管理面验收；里程碑表标注代码状态。
7. §8 明确逻辑在 `she_network/`，与存储解耦、管理入口同页。
8. 跨端读增加 owner 直读回退（master `not_found`/离线无缓存）。
9. `listSnapshots`/GFS 与再保护包隔离；再保护打包跳过既有 `reprotect-*`。
10. master/本机 store 所在卷 ≥80% 用量告警（`VolumeUsage` + `stats.volume_*`）。
11. 再保护包独立保留：最新 4 份，多余进回收站。
12. 旧 master 可达时升主差量镜像种子（`MirrorSeedService` + `seed: true` ACL）。
14. 自动快照告警按墙钟 3 天（成功或启用锚点），与同日失败次数解耦。
15. 回收站管理 UX：清空仅 master 本机、还原反馈、列表展开；Go ACL 对齐 `seed: true`。
16. Go `storage-node` 回收站路径/`recycle.restore`/stats/`commit` 字段与 Dart/spec 对齐。
17. 快照手动导出按 manifest 打包本机附件（`SnapshotExportResult`）。
18. 路径 A/B 导入请求到达通知（`ImportRequestNotifier` + `ImportRequestBus`）。
19. 新设备收到导入授权推送通知（`ImportGrantNotifier` + `ImportGrantBus`）。
20. 开启自动快照强制验密；管理页解密自检（`checkDecryptAndCache`）。
21. 危险区本机 store 树导出（`StoreExportService`，跳过 staging）。
22. master 上手动删除旧 device 镜像（`purgeDevice` + 清游标；禁删本机）。
23. 危险区删除本机 store 数据（`StoreWipeService` / `wipeSelf`，输入 DELETE；清队列保留 seq）。
24. 按设备/分区浏览与手删（`StorageBrowserScreen`；master 可删他端镜像）。
25. `commit.retention` 落地（`keep_last` / `gfs`；快照与再保护接入；Go 对齐）。
26. 危险区 WebDAV 兜底导出（`StoreWebdavExportService` + Dio MKCOL/PUT）。
27. M7 无头管理面（`storage-node` `/admin`：stats/回收站 + token/loopback 鉴权）。
28. M7 无头导入授权审批（Go `import.*` + `/admin` 批准/拒绝；私有读 grant 校验）。
29. M7 Noise IK 配对（`/peer/ws` + fingerprint device_id；`/admin` 开始/批准配对）。
30. M7 已配对重连（`/peer/ws`：无配对码时按 fingerprint 匹配 `paired_peers`，`reconnect_ack` 后加密 store 帧）。
31. M7 Channel 端点写入配对 QR / `PairingResponse`（`-channel` / `SHEPAW_CHANNEL_ENDPOINT`；App 扫码可外网连节点）。
32. M7 无头手删他端镜像（`PurgeDevice` + 清游标；`/admin/api/devices/purge`；配对持久化 `channel` 回退 QR）。
33. M7 无头分区浏览手删（`AdminList`/`AdminDelete`；`/admin/api/browse`；对齐 App `StorageBrowserScreen`）。
34. M7 无头危险区 wipeSelf（`WipeSelf`；`/admin/api/devices/wipe-self` 需 `confirm=DELETE`；不动他端/回收站/.system）。

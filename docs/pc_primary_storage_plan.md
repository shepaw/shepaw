# PC 主存储方案：PC = 工作站，移动端 = 控制台

> 状态：草案 v4（确定 hub 双实现策略：Flutter 内置 + Go daemon，弃用 Rust 方向）
> 定位依据：PC 是 Agent 工作站与唯一数据事实源，手机是随身控制台；数据不出用户自己的硬件。

## 1. 目标与非目标

**目标**
- hub（主存储）保存全部聊天、Agent 配置、记忆、附件，是系统唯一事实源。
- hub 有两种实现（第 7 节）：Flutter 桌面版内置（默认路径）、Go 独立 daemon（常开 Linux 无头场景）。
- 配对后**自动确立主从角色**：桌面端默认为主设备（hub），移动端默认为控制台（console），用户无需手动配置。
- 提供**存储空间管理页**：可视化管理配对设备角色、同步状态、存储用量，支持显式指定/切换主存储设备。
- 配对时手机上已有的本地数据一次性归并到 hub，此后手机切换为副本模式。
- 移动端通过 E2E 加密通道连接 hub，实时同步只读副本，并能下发写操作命令。
- hub 提供版本化快照备份，目的地由用户自选（本地目录 / NAS / WebDAV / S3 兼容）。
- 断网可用性分级：手机离线时只读，hub 离线时手机功能降级但可浏览已同步数据。

**非目标（明确不做）**
- 不做多主同步 / 多设备并发写冲突合并（多主是深坑，本期不碰）。
- 不做陌生人 / 开放网络的 P2P 互助备份。
- 不做实时协作编辑级别的 CRDT。
- 不改变两台手机之间现有 peer 聊天的语义（手机对手机不进入主从同步）。
- 不用 Rust 重写任何组件；不在 App 端内通过 FFI 嵌入原生存储库（移动端无法管理独立二进制进程，iOS 禁止 spawn）。
- 同步≠备份：删除会随同步传播，备份走独立快照链路。

## 2. 角色与拓扑

```
        ┌──────────────────────┐
        │  Hub / 主存储          │
        │  = Flutter 桌面版 或   │
        │    Go daemon (Linux)  │
        │  - SQLite 主库         │
        │  - Agent 运行环境      │
        │  - PeerLocalServer    │◄──── LAN 直连 (WS + Noise, 端口 18792)
        │  - 快照备份引擎        │
        └──────────┬───────────┘
                   │
                   │ 远程时复用 Channel Tunnel (channel_tunnel_service)
                   │
        ┌──────────┴───────────┐
        │  Mobile (Console)     │
        │  - 只读副本 SQLite     │
        │  - 写命令队列          │
        │  - 通知 / 审批入口     │
        └──────────────────────┘
```

原则：**手机永不监听端口、永不做主**。所有写操作收敛到 hub，由 hub 分配全局顺序。角色在配对握手时自动判定（见第 4 节），持久化后不做自动升降级，只能由用户在存储管理页显式变更（见第 5 节）。

## 3. 复用现有资产

| 能力 | 现有实现 | 复用方式 |
|------|---------|---------|
| E2E 加密会话 | `lib/peer/services/peer_connection.dart`（WS + Noise，收发队列锁保证 nonce 有序） | 同步协议直接跑在其控制帧上 |
| 局域网服务 | `lib/peer/services/peer_local_server.dart`（固定端口 18792，`/peer/ws`） | hub 常驻监听 |
| 远程隧道 | `lib/services/channel_tunnel_service.dart`、`peer_channel_bridge.dart` | 异地时走隧道，协议不变 |
| 设备配对 | QR 配对 + `paired_peers` 表（public_key / fingerprint / pairing_role） | 握手时交换设备信息，新增主从角色字段 |
| 存储 | `LocalStorageService` + DAO 层（`lib/services/database/*_dao.dart`） | 表结构加同步元数据 |
| 导出 | `data_export_import_service.dart` | 初始数据归并与快照备份共用序列化/加密逻辑 |
| Go 协议层 | agent-bridge（Go 实现的 peer/Noise 接入） | 抽共享 protocol package，供 Go hub daemon 复用 |

## 4. 配对与初始数据归并

### 4.1 角色自动判定

配对握手时双方交换 `device_info`：

```json
{"platform": "macos|windows|ios|android", "app_version": "1.0.17",
 "hub_capable": true, "device_name": "Eden 的 MacBook"}
```

默认规则与例外：

- **桌面 + 移动**：桌面端自动为 hub，移动端自动为 console——这是默认路径，用户无感知。
- **双方都是桌面端**：配对确认页让用户选择谁是主设备（默认展示二维码的一方）。
- **console 已绑定过其他 hub**：提示"已绑定工作站 X"，绑定新 hub 需显式确认切换；切换时清空本地副本并重新走初始同步。
- **两台手机配对**：不确立主从，保留现有 peer 聊天行为，不开启同步。
- **Go daemon 作为 hub**：daemon 无屏幕，配对通过 daemon 输出的一次性配对码 / Web 管理页完成，角色恒为 hub。

角色持久化：`paired_peers` 表新增两列：

```sql
ALTER TABLE paired_peers ADD COLUMN device_role TEXT;   -- hub | console | none
ALTER TABLE paired_peers ADD COLUMN sync_enabled INTEGER NOT NULL DEFAULT 0;
```

配对之后如需变更角色，走存储空间管理页的主备切换流程（第 5 节），不自动变更。

### 4.2 首次同步：手机已有数据的归并

配对时手机往往已有本地数据（Agent、会话、记忆）。采用"**一次归并、单向切换**"：

1. 角色确立后，若手机本地业务表非空，hub 发起 `sync.adopt.begin`。
2. 手机将本地数据按表序列化为 `sync.adopt.batch`（复用 `data_export_import_service` 的导出格式），逐表发送；记录保留原 uuid。
3. hub 在单个事务内归并：按 uuid 去重，冲突时保留 `updated_at` 较新者；为每条入库记录分配 `seq`。
4. 归并完成后 hub 回 `sync.adopt.done`；手机**清空本地业务表**，然后走 6.5 快照导入完成首次全量同步。
5. 从这一刻起手机进入 console 模式：读副本、写命令，本地不再产生权威数据。

保护措施：

- 归并前 hub 自动做一次快照（第 8 节），归并出错可整体回滚。
- 手机清空本地表前，先保留一份本地导出文件，7 天后自动删除。
- 归并过程断线：手机端数据未清空前可随时安全重试，hub 端按 uuid 幂等去重，重复归并不产生重复数据。

### 4.3 配对状态机

```
unpaired → role_negotiated → adopting（手机有本地数据时）→ snapshot_sync → active
```

- 每个阶段失败可回到上一阶段重试，不产生中间脏状态。
- 配对确认页展示进度条与当前阶段，避免用户在归并大库时误以为卡死。

## 5. 存储空间管理页

入口：设置 → 数据存储。hub 与 console 打开同一页面，权限不同（见 5.2）。Go daemon 场景下，console 通过协议读取 hub 上报的统计信息。

### 5.1 页面信息架构

1. **主存储设备卡片**（顶部）：当前 hub 的设备名、实现类型（桌面版 / Go daemon）、在线状态；主库大小、附件占用、快照占用、当前 seq 水位。
2. **配对设备列表**：每台设备一行——角色 badge（主存储 / 副本）、平台图标、连接状态、同步游标与落后条数、最近同步时间、该设备副本占用空间。操作：
   - **设为主存储设备**（触发 5.3 切换流程）
   - 撤销配对（hub 执行，立即拒绝该设备后续所有帧）
   - 清除本机副本数据（console 自清理，不影响 hub）
3. **备份区块**：目的地列表与状态、最近一次快照时间、保留策略、"立即快照"按钮。
4. **危险区**：停止同步、重置本机副本、导出全部数据。

### 5.2 权限模型

- 角色变更与配对撤销**只能由当前 hub 执行**。
- console 侧页面默认只读，顶部标注"由工作站 X 管理"；"设为主存储"按钮变为**申请**——向 hub 发 `sync.role.request`，hub 端确认后才进入切换流程。
- console 可自助的操作仅限：查看、清除本机副本、导出数据。

### 5.3 主备切换协议（`sync.role.switch`）

切换是全系统最危险的操作，必须在线协调、可回滚、防双主：

1. **前置校验**：目标设备在线、`hub_capable`、副本游标已追平（落后为 0；未追平则先增量同步，追平前切换按钮置灰）。
2. **维护态**：旧 hub 暂停接受新写命令与本地写，UI 提示"切换中"。
3. **追平确认**：目标设备对最新 `seq` 回 `ack`，旧 hub 确认双方数据一致。
4. **角色翻转**：生成新 `epoch`（旧值 +1），双方在各自事务内更新 `device_role`：目标 → hub，旧 hub → console。
5. **新 hub 接管**：`sync_clock` 从 `max(seq) + 1` 继续分配；向其余 console 广播新 hub 地址与 `epoch`。
6. **旧 hub 降级**：清除写权限标记，转为副本模式，开始从新 hub 增量拉取。
7. **失败回滚**：任一步失败，旧 hub 退出维护态恢复写，`epoch` 不变，目标设备角色不变。

**防脑裂（epoch fencing）**：所有 `sync.*` 帧携带 `epoch`；设备只接受当前 `epoch` 的 hub 下发的命令。旧 hub 若在降级完成前断网又恢复，其 `epoch` 已过期，写命令一律被拒绝并提示重新同步角色。

**约束**：切换双方必须全程在线；任一离线则不允许发起。切换期间写暂停窗口预期 < 5 秒。Go daemon 与 Flutter hub 之间切换同样适用（此时 Flutter hub 降级为 console 纯副本）。

### 5.4 存储用量统计

- hub 端在页面打开时 + 每日统计一次：`PRAGMA page_count` 得库大小、遍历附件目录与快照目录；Go daemon 通过 `sync.stats` 帧上报。
- 提供按表 / 按会话的占用 breakdown，帮助用户决定清理范围；清理操作复用墓碑机制，随同步传播到各副本。

## 6. 同步协议设计

> 协议的唯一权威定义在独立的 `docs/sync_protocol_spec.md`（版本化），Dart 与 Go 实现都以它为准。本节为概述。

### 6.1 数据模型改造（hub 主库）

每张需要同步的表增加三列：

```sql
ALTER TABLE messages   ADD COLUMN seq INTEGER;      -- hub 分配的全局单调序号
ALTER TABLE messages   ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE messages   ADD COLUMN deleted INTEGER NOT NULL DEFAULT 0;  -- 墓碑
```

- `seq` 由 hub 在事务内从一张 `sync_clock` 表单点分配，保证全局单调。
- 删除一律软删除（墓碑），墓碑保留 30 天后由 hub 定期清理；清理前必须已同步给所有已配对设备。
- 新增 `sync_devices` 表：记录每个配对 console 的同步游标 `last_ack_seq`、当前 `epoch`。

### 6.2 拉取协议（console → hub）

复用 `PeerMessage` 控制帧，`sync.*` 命名空间（所有帧携带 `epoch`）：

```json
// console 请求（连接建立后自动发起）
{"ns": "sync", "op": "pull", "cursor": 10234, "limit": 500, "epoch": 3}

// hub 响应（分批，带结束标记）
{"ns": "sync", "op": "changes", "from": 10235, "to": 10734,
 "tables": {"messages": [...], "channels": [...]}, "has_more": true}

// console 确认落库后回执（游标推进）
{"ns": "sync", "op": "ack", "cursor": 10734}
```

- console 收到 `changes` 后在**单个 SQLite 事务**内 upsert，成功才发 `ack`；失败则下次从旧游标重拉（幂等：`INSERT OR REPLACE`）。
- hub 端有新增 `seq` 时主动向在线 console 推 `sync.notify`，console 收到即发起 `pull`，实现近实时。

### 6.3 写入路径（console → hub）

手机上的任何写操作（发消息、改配置、审批）不直接写本地副本，而是封装为命令：

```json
{"ns": "sync", "op": "cmd", "cmd_id": "uuid", "type": "message.send",
 "payload": {...}, "client_ts": 1721300000, "epoch": 3}
```

- hub 校验（含 `epoch` 检查）后在事务内落主库、分配 `seq`，回 `cmd.ok`（携带分配的 seq）或 `cmd.err`。
- console 本地维护 `pending_commands` 队列：发出后乐观展示（灰态），收到 `cmd.ok` 转正式态；离线时排队，重连按序重放，`cmd_id` 去重防重。
- **MVP 简化**：离线不允许写，只允许读；写命令仅在连接状态可发。

### 6.4 附件与大文件

- 消息体只同步元数据 + 附件描述（`hash`, `size`, `mime`）。
- 附件二进制按需拉取：`sync.blob.pull {hash, offset, length}`，64KB 分块，SHA-256 校验，哈希去重。
- 手机端默认只拉缩略图，原文件点击再拉，省流量省空间。

### 6.5 首次全量：快照直灌

首次全量同步不回放历史记录，而是由 hub 生成一次快照（`VACUUM INTO` + 附件清单），通过加密通道直接灌给手机导入；导入后手机从快照水位 `seq` 开始增量。大数据量用户的首同步从小时级降到分钟级。

## 7. Hub 实现策略：Flutter 内置 + Go daemon

### 7.1 决策

- **协议是契约**：`docs/sync_protocol_spec.md` 是帧格式与状态机的唯一权威定义，独立于任何实现，带版本号。
- **实现一：Flutter 桌面版内置 hub（Dart）**——M1~M4 的产品闭环路径，覆盖"PC 桌面版作主存储"的默认场景。
- **实现二：Go 独立 daemon（新仓库 `shepaw-hub`）**——面向常开 Linux（NAS / 旧主机 / VPS）无头场景，解决 PC 休眠导致手机失联的问题；此时手机与 PC 桌面版均为 console。
- **弃用 Rust**：agent-bridge 已是 Go 实现，复用其 peer/Noise 协议层即可；引入第三语言（工具链、CI、协议三端维护）的成本大于收益。
- **端内不嵌原生库**：App 内部存储维持 sqflite + DAO；hub 逻辑不进移动端，移动端与 hub 之间只有网络协议（iOS 无法 spawn 子进程，FFI 化收益为负）。

### 7.2 Go daemon 技术选型

- WebSocket：`nhooyr.io/websocket`（或 gorilla）
- Noise：`flynn/noise`——与 agent-bridge 共享或抽公共 protocol package
- SQLite：`modernc.org/sqlite`（纯 Go 无 cgo），`GOOS/GOARCH` 直接交叉编译 NAS/ARM 二进制
- 仓库关系：独立二进制、独立部署；若与 agent-bridge 同一维护者，可同 module 双命令（`cmd/agent-bridge`、`cmd/hub`）共享 protocol 包
- agent-bridge 管理的 agent 需要存取数据时，走 hub 协议或 hub 本地 API，**不自带存储**——存储所有权唯一

### 7.3 协议一致性

- 协议版本号独立于 `epoch`（epoch 防角色脑裂，协议版本防帧格式错配），握手时双方校验协议版本。
- 跨语言一致性测试：共享测试 fixture（扩展 `tool/generate_interop_fixture.dart` 的先例），Dart 与 Go 实现跑同一份用例。
- **启动时机**：协议演化期（M1~M4）只维护 Dart 实现，协议稳定后再启动 Go 实现，避免双倍 churn；若"常开 Linux hub"被判定为核心场景，可提前至 M2 并行，但需接受协议变更期的双倍成本。

## 8. 备份（快照链路，独立于同步）

1. **快照生成**（hub 端，定时 + 手动触发）：
   - 数据库用 SQLite `VACUUM INTO` 生成一致性快照（比文件拷贝安全，无需停写）。
   - 附件目录按哈希去重后增量打包。
   - 清单文件 `manifest.json`：快照时间、seq 水位、文件哈希列表。
2. **加密**：主密码派生密钥（复用 `SecureKeyManager` 的 KDF），快照整体加密后落盘——备份目的地不信任。Go daemon 场景由 daemon 持有用户设置的备份密码，或快照明文只写本地加密盘。
3. **目的地**（插件化，先两个）：本地目录（可指向 NAS 挂载点）、WebDAV。S3 兼容后续加。
4. **保留策略**：GFS——保留最近 7 个日快照、4 个周快照、12 个月快照。
5. **恢复**：一键恢复 + 恢复前自动对当前库做一次快照兜底。每次发版前在 CI 跑一次"快照→恢复→打开"演练。

## 9. 安全

- 传输：复用 Noise E2E；配对新设备需 hub 端现场确认指纹（已有 fingerprint 机制）。
- console 丢失：存储管理页一键撤销该设备配对，并拒绝其游标之后的任何 `cmd`。
- 备份加密密钥只从主密码派生，不落地明文。
- 角色变更（`sync.role.*`）帧必须在 Noise 加密通道内传输，且 hub 端需用户在场确认（Go daemon 场景为其 Web 管理页的本地确认），防止远程劫持主设备身份。

## 10. 分阶段实施

| 阶段 | 内容 | 验收标准 |
|------|------|---------|
| M1 角色与归并 | `sync_protocol_spec.md` v1 + 4.1 角色判定 + 4.2 数据归并 + 6.1 表改造 + 6.2 拉取协议 + 6.5 快照首同步 + 存储管理页（只读：角色、用量、游标展示） | 配对后 PC 自动为主；手机存量数据完整出现在 PC；管理页正确展示各设备角色与同步进度 |
| M2 写命令 | 6.3 命令通道（在线才允许写） | 手机发消息/审批，PC 落库并回执；`cmd_id` 重放不重复 |
| M3 附件 | 6.4 分块拉取 | 图片缩略图秒开，原文件按需下载，哈希校验通过 |
| M4 备份 | 第 8 节快照 + 本地目录/WebDAV + 恢复 | 删掉 hub 库后从 24h 内快照完整恢复 |
| M5 远程访问 | 复用 channel tunnel 跑同一协议 | 4G 网络下手机可连家里 hub，功能与 LAN 一致 |
| M6 主备切换 | 5.3 切换协议 + epoch fencing + 管理页操作入口 | 在线切换后无数据丢失、无双主；中途断网回滚干净；过期 epoch 的命令被拒绝 |
| M7 Go hub daemon（可选，协议稳定后） | `shepaw-hub` 仓库 + 7.2 选型 + 协议一致性测试 | 同一手机分别连 Flutter hub 与 Go hub，行为一致（fixture 全绿）；Linux 常开设备 7×24 运行 |

Dart 侧新增代码集中在 `lib/sync/`（sync_protocol、sync_cursor_store、cmd_queue、adopt_service、snapshot_service、role_switch_service），页面为 `lib/screens/storage_management_screen.dart`，`lib/peer/` 只加 `sync.*` 帧路由与角色协商，不侵入聊天逻辑。

## 11. 主要风险与对策

- **归并冲突**：uuid 去重 + `updated_at` 新者胜 + 归并前强制快照；极端情况用户可从备份回滚。
- **主备切换脑裂**：epoch fencing + 全程在线协调 + 失败回滚；切换期间写暂停窗口预期 < 5s。
- **hub 休眠/关机导致手机失联**：手机端明确展示"工作站离线"态而非假装在线；Go daemon（M7）是根治方案，此前引导用户设置 PC 自动唤醒（WOL）。
- **双实现漂移**：协议规范独立版本化 + 共享 fixture 一致性测试；协议稳定前只做 Dart 实现。
- **seq 单点分配的性能**：单用户量级下 SQLite 事务内分配足够，无需预研分布式时钟。
- **墓碑膨胀**：30 天清理 + `sync_devices` 强制落后设备全量重同步（跳过墓碑窗口）。
- **角色误判**：角色只在配对握手或管理页显式变更，不自动变更；所有角色帧要求 hub 端在场确认。

## 12. 后续可选（不承诺）

- 信任圈备份：家人/朋友的 ShePaw 设备互为加密快照目的地（仍不涉及开放网络）。
- 多 hub 场景：仍单主，第二台只作为备份目的地 + 通过管理页手动切换主备（M6 已覆盖切换路径）。

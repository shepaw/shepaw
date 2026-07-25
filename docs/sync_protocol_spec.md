# ShePaw 主从同步协议规范

> 版本：v1（M1 范围）
> 状态：草案，作为 Dart 与（未来）Go 实现的唯一权威定义。任何实现与本文档冲突时以本文档为准。
> 上游设计：`docs/pc_primary_storage_plan.md`（第 4/5/6 节）。本文档是其实现级细化。

## 0. 术语

| 术语 | 含义 |
|------|------|
| hub | 主存储设备（Flutter 桌面版内置，或 Go daemon）。系统唯一事实源，分配全局 `seq`。 |
| console | 副本设备（移动端，或降级后的桌面端）。只读副本 + 写命令通道（写命令为 M2，本文档仅保留帧名）。 |
| 传输层 | 既有 `PeerConnection`（WS + Noise E2E）或 Channel Tunnel。本协议全部跑在其控制帧上，不新增传输。 |
| `seq` | hub 单点分配的全局单调序号（SQLite 事务内从 `sync_clock` 表分配）。 |
| `epoch` | 角色代际号，主备切换时 +1。用于防双主（epoch fencing）。M1 恒为 1。 |
| 协议版本 | 帧格式版本号，独立于 `epoch`。本文档为 `1`。握手时校验，不兼容则拒绝同步。 |

## 1. 帧格式

所有同步帧复用 `PeerConnection` 控制帧通道（`sendControl`），载荷为 JSON：

```json
{
  "type": "sync",
  "ns": "sync",
  "op": "<操作名>",
  "epoch": 1,
  "v": 1,
  "...": "op 特有字段"
}
```

- `type` 恒为 `"sync"`：peer 层按扁平 `type` 路由控制帧（`PeerConnection._controlTypes`），该字段是传输映射，使 sync 帧不进入聊天持久化逻辑。
- `ns` 恒为 `"sync"`：协议层命名空间，供未来多命名空间复用同一 `type` 路由或 Go 实现校验。
- `op` 见第 4 节操作清单。
- `epoch` 发送方当前认知的角色代际号。接收方校验：与本地持久化的 `epoch` 不一致的帧一律拒绝（M1 双方恒为 1，校验逻辑先落地，切换在 M6 启用）。
- `v` 协议版本。本版恒为 `1`。双方 `v` 不一致时，高版本方必须能以低版本语法交互，否则回 `sync.error` 带 `unsupported_version` 并停止同步。
- 响应帧不强制携带请求 ID；`pull/changes/ack` 为单连接串行流水线，`adopt.*` 由阶段状态机保证一对一。

### 通用错误帧

```json
{"ns": "sync", "op": "error", "epoch": 1, "v": 1,
 "ref_op": "pull", "code": "<错误码>", "message": "人类可读描述"}
```

错误码（M1）：

| code | 含义 | 接收方行为 |
|------|------|-----------|
| `epoch_mismatch` | epoch 过期/不一致 | 停止同步，等待角色重新协商（M6 前表现为报错提示） |
| `unsupported_version` | 协议版本不兼容 | 停止同步，提示升级 |
| `not_paired` / `role_invalid` | 未配对或对方角色不允许该 op | 终止会话 |
| `cursor_too_old` | 游标落后超过墓碑保留窗口 | console 触发全量重同步（走第 7 节快照流程） |
| `busy` | hub 处于归并/快照/维护态 | 稍后重试 |
| `internal` | 其他内部错误 | 记录日志，可重试 |

## 2. 角色协商（配对握手扩展）

### 2.1 device_info

配对握手（既有 QR 配对流程）中，双方在认证完成后、配对持久化前交换：

```json
{
  "platform": "macos|windows|linux|ios|android",
  "app_version": "1.0.17",
  "hub_capable": true,
  "device_name": "Eden 的 MacBook"
}
```

- `hub_capable`：桌面平台（macos/windows/linux 且非 daemon 纯 console 模式）为 `true`；移动端恒为 `false`。
- 该载荷在既有配对握手消息中作为扩展字段携带（实现侧映射到具体握手消息，见实现注释 §2.4）。

### 2.2 角色判定规则（确定性，双方各自计算结果必须一致）

1. 一方 `hub_capable=true` 另一方 `false`：前者为 **hub**，后者为 **console**。（桌面+移动默认路径）
2. 双方都是移动端：**不确立主从**（`device_role=none`，`sync_enabled=0`），保留现有 peer 聊天行为。
3. 双方都是桌面端：**用户选择**。展示二维码的一方默认建议为 hub，配对确认页提供选择；选择结果由发起方在确认消息中带回，双方落库一致。
4. Go daemon 参与的配对恒为 hub（daemon 无屏幕，由一次性配对码/Web 管理页完成，M7 范围）。

### 2.3 持久化

`paired_peers` 新增列：

```sql
ALTER TABLE paired_peers ADD COLUMN device_role TEXT;              -- 'hub' | 'console' | 'none'（本地视角：对方设备的角色即本机角色的互补，存储的是"对端角色"）
ALTER TABLE paired_peers ADD COLUMN sync_enabled INTEGER NOT NULL DEFAULT 0;
```

> 约定：`paired_peers.device_role` 记录**对端设备**的角色。本机角色由对端角色互补推导：对端=hub ⇒ 本机=console，对端=console ⇒ 本机=hub，对端=none ⇒ 无主从。本机同时最多一个 hub 对端。

确立主从（role ∈ {hub, console}）时 `sync_enabled=1`，并初始化 `epoch=1`。

### 2.4 配对状态机

```
unpaired → role_negotiated → adopting → snapshot_sync → active
```

- `role_negotiated`：2.2 判定完成、角色已持久化。
- `adopting`：仅当 console 本地业务表非空时进入；否则跳过。
- `snapshot_sync`：hub 生成快照直灌 console（第 7 节）。
- `active`：增量同步运行中（第 5/6 节）。
- 每阶段失败回到上一阶段重试，不产生中间脏状态（各阶段幂等，见各节）。状态机由 console 侧驱动、hub 侧镜像；双方将当前阶段持久化，重连后从持久化阶段继续。

## 3. 数据模型（hub 主库 & console 副本共有）

每张同步表增加：

```sql
ALTER TABLE <t> ADD COLUMN seq INTEGER;                            -- hub 分配的全局序号；console 侧为只读镜像
-- updated_at 本就存在（agents INTEGER ms / channels TEXT ISO）或新增 INTEGER ms（messages/channel_members/resources）
ALTER TABLE <t> ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;  -- 仅原本缺失的表新增
CREATE INDEX idx_<t>_seq ON <t>(seq);
```

**实现决策（v1，与原案的两点偏离）**：

1. **seq 由 hub 侧 SQLite 触发器分配**（`AFTER INSERT/UPDATE`，带 `WHEN NEW.seq = OLD.seq` 防递归守卫），而非侵入各 DAO 写路径。触发器仅在设备成为 hub 时安装、降级时摘除；console 永不安装，副本行的 `seq` 由 hub 帧原样携带。hub 激活时对存量行按 rowid 顺序回填 seq（单事务）。
2. **删除不落 `deleted` 列，改由 `sync_tombstones` 日志表传播**（`AFTER DELETE` 触发器写入，携带新分配的 `seq`）。这样既有读路径无需追加 `WHERE deleted=0`，既有硬删除路径（DAO `db.delete`）零改动即可被同步捕获。帧中的 `deleted=1` 条目由墓碑行派生。

- 删除一律经墓碑传播；墓碑保留 30 天由 hub 定期清理；清理前确认所有 `sync_devices.last_ack_seq` 均已越过该墓碑的 `seq`，越不过的设备下次拉取回 `cursor_too_old`（M1 暂未实现自动清理，墓碑持续增长在单用户量级下可接受）。

hub 专属表：

```sql
CREATE TABLE sync_clock (id INTEGER PRIMARY KEY CHECK (id = 1), next_seq INTEGER NOT NULL);
CREATE TABLE sync_devices (
  peer_id TEXT PRIMARY KEY,          -- 配对关系 id（paired_peers.id）
  last_ack_seq INTEGER NOT NULL DEFAULT 0,
  epoch INTEGER NOT NULL DEFAULT 1,
  state TEXT NOT NULL DEFAULT 'active',  -- hub 侧镜像的该设备状态机阶段
  updated_at INTEGER NOT NULL DEFAULT 0
);
```

console 专属表：

```sql
CREATE TABLE sync_cursor (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  last_applied_seq INTEGER NOT NULL DEFAULT 0,
  epoch INTEGER NOT NULL DEFAULT 1,
  hub_peer_id TEXT,
  state TEXT NOT NULL DEFAULT 'unpaired'   -- 第 2.4 节状态机
);
```

- `seq` 分配：触发器在写事务内 `UPDATE sync_clock SET next_seq = next_seq + 1`（与业务写入同事务）。

**M1 同步表清单**（`SyncTableRegistry` 为准）：
`agents`、`channels`、`channel_members`（身份键为 `(channel_id, agent_id)` 复合键，本地自增 `id` 不传输）、`messages`、`resources`（附件元数据；附件二进制在 M3）。
`agent_memories`（每 agent 独立库、无跨设备稳定键）不在 M1，后续里程碑单独设计归并键。

## 4. 操作清单

| op | 方向 | 阶段 | 说明 |
|----|------|------|------|
| `hello` | console → hub | 连接建立后 | 上报本地状态机阶段/游标/是否有本地数据，hub 据此驱动后续阶段 |
| `adopt.begin` | hub → console | adopting | 要求 console 序列化本地数据上送 |
| `adopt.batch` | console → hub | adopting | 一批记录（按表分帧） |
| `adopt.done` | hub → console | adopting | 归并完成，console 可清库 |
| `snapshot.begin` | hub → console | snapshot_sync | 快照元信息（大小、seq 水位、清单哈希） |
| `snapshot.next` | console → hub | snapshot_sync | 流控：就绪接收第 N 块（每块确认） |
| `snapshot.chunk` | hub → console | snapshot_sync | 快照数据块（64KB，序号 + 末块标记） |
| `snapshot.done` | console → hub | snapshot_sync | console 导入完成确认 |
| `pull` | console → hub | active | 增量拉取 |
| `changes` | hub → console | active | 变更批次 |
| `ack` | console → hub | active | 游标推进回执 |
| `notify` | hub → console | active | 有新 seq，催促 pull |
| `stats` | 双向 | active | 存储/同步统计（管理页数据源） |
| `error` | 双向 | 任意 | 通用错误 |

M2+ 保留（M1 不实现、收到回 `unsupported_version` 之外不处理）：`cmd` / `cmd.ok` / `cmd.err`、`blob.pull` / `blob.chunk`、`role.request` / `role.switch.*`。

## 5. 增量拉取（active）

### 5.1 pull / changes / ack

```json
// console → hub（连接建立并完成握手后自动发起）
{"ns":"sync","op":"pull","v":1,"epoch":1,"cursor":10234,"limit":500}

// hub → console（可多帧，has_more 标记）
{"ns":"sync","op":"changes","v":1,"epoch":1,"from":10235,"to":10734,
 "tables":{"messages":[{"key":"...","seq":10235,"updated_at":1721300000000,"deleted":0,"row":{...}}]},
 "has_more":true}

// console → hub（单事务落库成功后）
{"ns":"sync","op":"ack","v":1,"epoch":1,"cursor":10734}
```

规则：
- `changes` 每条记录：`key` 为身份键（uuid 表为 `id` 值，channel_members 为 `channel_id|agent_id`）；`row` 为整行（含 `seq`，排除本地自增列）。`deleted=1` 时 `row` 只含身份键列。
- console 在**单个 SQLite 事务**内对本批全部表 `INSERT OR REPLACE`，成功才发 `ack`；任何失败不发 `ack`，下次从旧 `cursor` 重拉（服务端幂等）。
- `limit` 上限 2000；hub 可返回小于 `limit` 的批次。
- hub 校验 `cursor < tombstone_min_seq` 时回 `error/cursor_too_old`。
- hub 收到 `ack` 后更新 `sync_devices.last_ack_seq`。

### 5.2 notify

hub 在写事务提交后向所有在线 console 单播：

```json
{"ns":"sync","op":"notify","v":1,"epoch":1,"latest":10735}
```

console 收到即发起 `pull`（带本地游标）。`notify` 可合并、可丢失（console 重连总会主动 `pull`，心跳兜底间隔 30s）。

## 6. 数据归并（adopting）

一次归并、单向切换。console 数据保留原 `uuid`，hub 幂等合并。

```json
// hub → console
{"ns":"sync","op":"adopt.begin","v":1,"epoch":1,"tables":["channels","messages","agents","agent_memories"]}

// console → hub（逐表分批，每批 ≤ 500 行；batch_no 从 0 递增）
{"ns":"sync","op":"adopt.batch","v":1,"epoch":1,"table":"messages","batch_no":0,"last":false,
 "rows":[{"uuid":"...","updated_at":1721300000000,"row":{...}}]}

// hub → console（全部批次入库后）
{"ns":"sync","op":"adopt.done","v":1,"epoch":1,"merged":{"messages":1203,"channels":12,...}}
```

规则：
- hub 在收到 `adopt.begin` 前列表为空时直接回 `adopt.done`（跳过）。console 在发送完全部表后置某帧 `last=true`。
- hub 对每批在**单事务**内：按 `uuid` 查重 → 已存在且本地 `updated_at` ≥ 上送值则跳过；否则 upsert 并分配 `seq`。重复批次（重试）不产生重复数据。
- hub 在 `adopt.begin` 前自动做一次本地快照兜底（快照链路 M4 才完整，M1 落盘到本地目录即可，失败仅告警不阻断）。
- console 收到 `adopt.done` 后：先把本地业务表导出为一个本地文件（保留 7 天后自动删除），再清空业务表，进入 `snapshot_sync`。
- 断线恢复：任一侧断线，重连后 console 从持久化的 `adopting` 状态继续，`adopt.begin` 重发；hub 幂等去重保证安全。

## 7. 快照首同步（snapshot_sync）

```json
// hub → console
{"ns":"sync","op":"snapshot.begin","v":1,"epoch":1,
 "snapshot_id":"20260726-120000","seq_watermark":11002,"db_bytes":7340032,
 "sha256":"<整体哈希>","manifest_sha256":"<清单哈希>"}

// console → hub（流控：就绪接收第 N 块；首块在 begin 处理完后请求）
{"ns":"sync","op":"snapshot.next","v":1,"epoch":1,"chunk_no":0}

// hub → console（chunk_no 从 0 递增；data 为 base64；末块 last=true）
{"ns":"sync","op":"snapshot.chunk","v":1,"epoch":1,"chunk_no":0,"last":false,"data":"..."}

// console → hub（导入成功）
{"ns":"sync","op":"snapshot.done","v":1,"epoch":1,"snapshot_id":"20260726-120000","applied_seq":11002}
```

规则：
- hub 用 SQLite `VACUUM INTO` 生成一致性快照（无需停写）；附件清单列入 `manifest.json`（M1 不传输附件二进制）。
- **水位先于快照**：hub 先取 `seq_watermark = currentSeq()` 再 `VACUUM INTO`，故快照内容 ⊇ {seq ≤ watermark}；console 从水位增量，重叠行靠幂等 upsert 吸收。
- **逐块确认流控**：hub 只在收到 `snapshot.next(chunk_no=N)` 后发送第 N 块，任一时刻至多一块在途，避免大快照撑爆发送缓冲。
- 分块 64KB，Noise 通道内传输，不再二次加密；`sha256` 整体校验失败则 console 丢弃临时文件、状态机停在 `snapshot_sync`，重连后 hub 重新生成并重传。
- console 导入（实现决策，替代"原子替换库文件"）：`ATTACH` 快照库后在单事务内**按同步表逐表替换**（`DELETE` + `INSERT ... SELECT`，列以本机 schema 为准、排除本地自增列），快照中 hub 的 `paired_peers`/`user` 等表绝不覆盖本机；置 `sync_cursor.last_applied_seq = seq_watermark`、`state=active`。
- hub 收到 `snapshot.done` 后把该设备 `sync_devices.last_ack_seq` 置为 `seq_watermark`、`state=active`。
- 此后进入第 5 节增量循环。

## 8. 统计帧（stats，管理页数据源）

```json
// console → hub（页面打开时）
{"ns":"sync","op":"stats","v":1,"epoch":1,"kind":"query"}

// hub → console
{"ns":"sync","op":"stats","v":1,"epoch":1,"kind":"report",
 "db_bytes":7340032,"attachment_bytes":0,"snapshot_bytes":0,
 "seq_watermark":11002,
 "devices":[{"peer_id":"...","role":"console","last_ack_seq":11002,"lag":0,"last_seen":1721300000000}]}
```

console 侧本机副本占用由本地统计补入同一页面，不经网络。

## 9. 安全约束

- 全部帧只在 Noise E2E 通道内传输；任何明文传输本协议帧的实现视为不合规。
- 角色确立/变更（M6 的 `role.*`）必须经 hub 端用户在场确认；M1 的自动判定以配对流程本身的双向确认为前提。
- console 断连重试须带持久化的 `epoch`；hub 拒绝一切 `epoch` 过期的帧。
- `adopt.*` 与 `snapshot.*` 帧体积大，实现侧必须复用 `PeerConnection` 的发送队列锁，保证与聊天帧混排时 nonce 有序。

## 10. 版本与兼容

- `v=1`（本文档）。新增 op 或必填字段 ⇒ `v+1`；只增可选字段不变版本。
- 握手（配对扩展字段）携带双方 `sync_protocol_version`，取 `min(双方)` 作为会话版本；`min < 1` 则 `sync_enabled=0`。
- Go 实现启动前，本规范须先冻结 M1~M4 所需帧；之后以共享 fixture（`tool/generate_interop_fixture.dart` 模式）做跨语言一致性测试。

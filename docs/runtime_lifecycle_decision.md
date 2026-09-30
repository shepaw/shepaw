# `runtime` 生命周期（决策记录）

- 日期：2026-09-28
- 状态：**已裁定，保留清理已落地**（2026-09-28）
- 关联：`docs/storage_space_plan.md`、`docs/storage_protocol_spec.md` §2.6/§2.8

## 1. 现状：`runtime` 只增不减

`runtime/<owner>/…` 下会长出来的东西（`lib/storage/runtime_paths.dart`）：

| 内容 | 落点 | 增长方式 |
|---|---|---|
| 会话 | `sessions/session.json` + `sessions/archive-<utc>.json` | 每轮归档一份，**无上限** |
| 附件 | `…/attachments/<sha256>` | 每收到一个附件一份，**无清理** |
| 产物 | `…/artifacts/<task>/<file>`（+ `.meta.json` sidecar） | agent 每次 `pouch write` 一份 |
| 镜像 | `soul.md` / `memory.md` / `workspace.md` | 覆盖写，但每次写都进 `.versions` |
| manifest | `context.manifest.json` | 覆盖写 |

**现有的闸门只有一条**：agent 分区软配额 2GiB
（`local_store.dart:150` `defaultAgentSpaceQuotaBytes`，覆盖
`{runtime, artifacts, attachments, cognition}`），加上卷余量 64MiB
（`volumeHeadroomBytes`）。命中后是 **`quotaExceeded` 直接拒绝写入**——不清理、不淘汰。

**已有的清理**（`StoreService.start()` 各跑一次，不周期执行）：

- `.recycle/<date>/…`：`gcRecycle()` 清 30 天前的日期目录；
- `.staging/`：`gcStaging()` 清残留会话。

两者都只在**启动时触发一次**——长期不重启的进程不会周期运行。

**真正只增不减的**：

- `.versions/<device>/<space>/…`：同窗口内合并（`versionCoalesceWindow`），
  但**没有版本数量上限也没有过期**，频繁重写的文件版本无限累积；
- runtime 内的会话归档、附件、产物：没有任何 TTL 或数量上限。

`CommitRetention`（`keep_last` / `gfs`）**不适用**于 runtime——它作用域是某分区下的顶层
目录，服务的是快照与再保护包。

## 2. 风险

1. 配额是硬墙且是"拒绝写入"：一个长期跑的 agent 攒到 2GiB 后，产物、附件、镜像
   全部写失败，用户只在失败那一刻才察觉。
2. `.versions` 不占 agent 配额（不在 `agentQuotaSpaces` 里），且清理只在启动时跑，
   所以它能悄悄吃掉整卷空间，绕过唯一的闸门。
3. 跨端镜像：任何自动删除都会进 `SyncJournal` 镜像到 master，等于**在所有设备上删**。

## 3. 方案对比

| 方案 | 做法 | 代价 |
|---|---|---|
| A 不动 | 靠配额兜底 | 撞墙即不可用；`.versions` / `.recycle` 完全失控 |
| B 全分区 TTL | 按 mtime 过期清理 runtime | 可能删掉用户还要的产物，代价不可逆 |
| C 分类保留（**推荐**） | 会话/附件有 TTL、产物不过期、版本与回收站有上限 | 需要区分"哪些能删"，实现比 B 复杂 |
| D 只做可观测 | 用量页 + 阈值告警 | 不解决增长，只让人早点发现 |

## 4. 裁定：分类保留 + 可观测

聊天权威在 SQLite。`sessions/session.json` 只是单向镜像（`RuntimeMirrorService`，
失败不影响聊天，不从文件回灌），窗口本身有上限。真正只增不减的是滚动出去的
`archive-*.json`。附件字节被消息 `pouch_uri` 引用，按时间删会让旧消息里的文件打不开。

- **产物 `artifacts/<task>/`：不删**。接近配额只提示。
- **`session.json`：不删**。
- **`archive-*.json`：每个 `sessions/` 留最新 3 份**，更老的走 `delete`（回收站 + journal）。
- **附件：只删没有消息再引用、且超过 24 小时的孤儿**。仍被引用的不删。
- **`.versions`：每文件 `keep_last` 10**。`protected` 条目不丢，所以总数可以超过 10。硬删，不进回收站。
- **`.recycle` / `.staging`：前台每小时再跑一遍**（启动时那次保留）。
- **群 runtime 与个人 runtime 同一套**（都在同一棵 `runtime/` 下）。
- **只在 App 前台跑**。长期不打开就不会清。

**执行约束**：
- 归档和孤儿附件走 `LocalStore.delete`；版本与回收站可以硬删。
- 归档与孤儿附件**只在 master 上跑**，避免多端各删一遍。版本目录不进 journal，每台设备清自己的 `.versions`。
- 孤儿判断只用本机消息库。消息库读失败就跳过附件清理，不冒险删。
- master 上其他 device 的归档会一并裁（删除经 journal 回到属主）；它们的附件不裁，因为本机消息库看不见那些引用。

## 5. 已关闭的问题

1. 不做成设置项。归档留 3 份、版本留 10、附件孤儿 24 小时，写死。
2. 产物只提示，不删。
3. 群与个人同一套。
4. 清理走前台（`RuntimeRetentionService`，每小时 + 回到前台时）。

## 6. 落地

1. 用量按子类统计 + 用量页展示 — 已做
2. `.versions` `keep_last` — 已做
3. `.recycle` / `.staging` 前台周期执行 — 已做
4. 归档 `keep_last` + 孤儿附件 — 已做（不是整段 TTL）
5. 配额 80% 提示（写明产物不会自动删除）— 已做

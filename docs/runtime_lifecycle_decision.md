# `runtime` 生命周期（决策记录）

- 日期：2026-09-28
- 状态：**方案待确认，未实现**
- 关联：`docs/storage_space_plan.md`、`docs/storage_protocol_spec.md` §2.6/§2.8

## 1. 现状：`runtime` 只增不减

`runtime/<owner>/…` 下会长出来的东西（`lib/storage/runtime_paths.dart`）：

| 内容 | 落点 | 增长方式 |
|---|---|---|
| 会话 | `sessions/session.json` + `sessions/archive-<utc>.json` | 每轮归档一份，**无上限** |
| 附件 | `…/attachments/<sha256>` | 每收到一个附件一份，**无清理** |
| 产物 | `…/artifacts/<task>/<file>`（+ `.meta.json` sidecar） | agent 每次 `store write` 一份 |
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

## 4. 推荐：C + D（分类保留 + 可观测）

按"删错了会有多痛"分层，而不是一刀切 TTL：

- **产物 `artifacts/<task>/`：不过期**。这是用户要的东西，只受配额约束。
- **会话 `sessions/`（含 archive）：TTL**，如 30 天；或按 channel `keep_last N`。
- **附件 `attachments/`：TTL**，与会话同策略（它们是会话上下文的一部分）。
- **`.versions`：每文件 `keep_last`（建议默认 10）**，超出的最老版本直接丢（不进回收站）。
- **`.recycle` / `.staging`：把启动一次的清理改成周期执行**（已有实现，缺调度）。
- **可观测**：用量页显示 runtime 各子类占用；接近配额（如 80%）时提示。

**执行约束（必须遵守）**：
- 清理走既有 `LocalStore.delete` 语义（进回收站 + 入 SyncJournal），
  只有版本与回收站这两种"系统目录"可以硬删；
- 只在 master 设备上跑清理定时任务，避免多端各删一遍互相打架；
- 默认策略保守（TTL 30 天、产物不过期），清理动作可审计（记事件）。

## 5. 未决问题

1. TTL 默认值与是否用户可配（App 设置项？还是写死）。
2. 产物要不要也加"长期未访问"的软淘汰（而不是硬删）——比如只提示不删。
3. 群 runtime（owner 是群）与个人 runtime 是否同一套策略。
4. 清理任务是前台定时（App 运行时）还是后台任务（已有 `ForegroundTaskService`）。

## 6. 落地顺序（确认后）

1. 用量按子类统计（sessions / attachments / artifacts / mirrors / versions）+ 用量页展示
2. `.versions` `keep_last` 上限（纯系统目录，风险最低）
3. `.recycle` / `.staging` 清理改周期执行（复用现有实现）
4. sessions / attachments TTL（默认 30 天，只在 master 跑）
5. 配额阈值提示

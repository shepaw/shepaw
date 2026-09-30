# 产物元数据落盘（决策记录）

- 日期：2026-09-28
- 状态：**方案待确认，未实现**
- 关联：`docs/storage_space_plan.md` §6.3、`docs/workspace_mount_decision.md`

## 1. 背景与问题

`shepaw pouch write --task <id> --desc <text>` 现在：

- `--task` 只作为路径段落盘：`runtime/<owner>/<channel>/artifacts/<task>/<file>`
  （`lib/storage/artifact_service.dart` `ArtifactUri.storePath`）——可按路径检索；
- `--desc` **完全不落盘**，只被拼进返回的那一行引用里
  （`ArtifactService._buildDescription`：`— <desc>，<size>，<producer> 产出`）。

后果：元数据「只写不查」。Agent 以为自己给产物打了描述，重启后这一信息只剩在聊天记录里。
上一轮已把这条写进命令描述（"--desc 只回显、不持久化、不可检索"），但那是止损，不是解决。

对照：**群任务产物是有元数据的**——`GroupArtifactRegistry` 会在群工作空间写
`shared/tasks/<orchestrationId>/artifact_plan.json` 与产物清单（`GroupWorkspaceService`
`writeTaskArtifactPlan` / `registerTaskArtifacts`，受 `structuredTasks` 开关控制）。
所以现状是「群任务有元数据，单 agent 产物没有」。

## 2. 选项

| 方案 | 形态 | 优点 | 代价 |
|---|---|---|---|
| A Sidecar（**推荐**） | `artifacts/<task>/<file>.meta.json` | 无共享可变状态，多 agent 并发写同一 task 不会互相覆盖；删除/重命名可按对处理 | 条目数翻倍；list/search 会看到 meta 文件 |
| B 按 task 清单 | `artifacts/<task>/manifest.json` | 一次读列出该 task 全部产物；与群任务清单形态一致 | 并发写要 read-modify-write，存在丢更新；单文件随产物增长 |
| C runtime 根索引 | `runtime/<owner>/<channel>/artifacts.index.json` | 一处查全量 | 写放大最大、竞争最激烈 |
| D 不落盘 | 现状 + 文档说明 | 零改动 | 元数据永久丢失，检索能力无从谈起 |

**推荐 A**：并发安全是硬约束（群成员会往同一个袋写），而 B/C 的共享文件在并发下必然丢更新。

## 3. 推荐方案（A）的数据形态

`artifacts/<task>/report.md.meta.json`：

```json
{
  "artifact": "report.md",
  "task": "task-41",
  "desc": "Q2 销售报告",
  "producer": "agent_xxx",
  "written_at": "2026-09-28T12:00:00Z",
  "size": 1234,
  "sha256": "…"
}
```

只存**写入事实**（谁、何时、描述、大小），不存规划/验收语义——那是群任务清单的职责，两者不合并。

## 4. 影响面

- **检索**：`LocalStore.search` 先比路径、不中再读正文（`_peekTextSnippet`），
  所以 sidecar 里的 desc **天然可被正文命中**，检索层不用改。但命中返回的是
  **meta 文件的 URI**，必须在 `StoreSearchCommand` 里映射回产物 URI
  （剥掉 `.meta.json` 后缀），否则 Agent 拿到的是元数据的地址。
- **扫描预算**：`searchScanLimit = 5000`（`local_store.dart:155`）。sidecar 让条目数翻倍，
  等于可扫描的产物数减半——需要考虑把 meta 排除在扫描之外、只在命中后做一次映射。
- **删除 / 回收站 / 重命名**：产物被删时 sidecar 会成孤儿。要么 delete 连带删除
  （需 StoreService 层支持"成对"），要么读取时容忍缺失（更简单，推荐）。
- **版本**：产物与 sidecar 各自版本化，`versions.list` 条数翻倍；`@v<n>` 语义需在文档里说明。
- **镜像 / 配额**：sidecar 走同一 write 路径，自动进 SyncJournal 镜像到 master；
  体积计入 runtime 软配额（`StoreSpace.agentQuotaSpaces`），增量极小。
- **隐私**：desc 可能含敏感信息；runtime 是 private 分区，跨端不可读，与现状一致。

## 5. 未决问题与推荐（结合现状给出，待确认）

1. **要不要给 meta 单独开检索字段** → **不做 store 层结构化索引**。
   精确 `--desc` 过滤要新增协议 op（Rust / Dart / TS 三端 + fixtures），而 sidecar 是
   文本文件，`LocalStore.search` 的正文回退（`_peekTextSnippet`）已经能命中它。
   所以在 CLI 层加 `--desc` 即可：正文检索 + 只保留 `.meta.json` 命中 + 映射回产物 URI。
   规模上也够用——runtime 是单 agent 的软配额分区，`searchScanLimit = 5000` 即便因
   sidecar 翻倍也远大于实际产物数。

2. **孤儿 sidecar** → **容忍缺失**，并在映射时顺手清掉噪音。
   产物没有服务层删除入口（`ArtifactService` 只有 write / read），删除实际来自
   `store delete`、UI、回收站、sync delete——任何一条都会留下孤儿，做"连带删除"堵不完。
   做法：命中 meta 后映射回产物 URI 时校验产物存在，不存在就丢弃这条命中。
   既不需要新协议，也不会让 Agent 拿到指向空气的 URI。

3. **产物成功、sidecar 失败** → **产物成功即成功，sidecar 尽力而为**。
   先写产物、再写 sidecar；sidecar 失败不回滚、不报错，只在返回里加
   `meta_written: false`。理由：产物本体才是价值，元数据是增强；因为元数据失败
   而报写失败会诱导 Agent 重写一遍，反而制造重复产物。

4. **是否与群任务清单统一检索入口** → **先不统一**。
   两者语义不同：群清单在 workspaces（shared），是规划与验收（slots、assigned_agent）；
   产物 sidecar 在 runtime（private），只记写入事实。群清单已有自己的读取路径
   （`GroupWorkspaceService` + 编排层注入），合并入口属于没被要求的工作量。
   若将来真要合并，再给命中加 `source: runtime_meta | group_manifest` 区分。

**附带一条实现约束**：sidecar 让搜索命中可能重复（产物本体与它的 meta 同时命中同一个词）。
映射阶段要折叠成一条，优先保留**产物本体**的命中。

## 6. 落地顺序（确认后）

1. `ArtifactService.writeArtifact` 写产物后追加写 sidecar（尽力而为，失败不回滚产物）
2. `StoreSearchCommand` 把 `.meta.json` 命中映射回产物 URI，并从扫描结果里折叠掉 meta 条目
3. `pouch read` / `list` 对 meta 的展示策略（默认隐藏 or 保留）
4. 卡面 / CLI 描述同步：说清 desc 现在可检索

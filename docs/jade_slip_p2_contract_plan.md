# P2 方案：把玉简从「可勾选的待办」升级成「可验收的工作契约」

> 基线：P0/P1 两条 worktree 分支（未合 main）。P2 叠在它们之上，合入顺序 P0/P1 → P2。
> 2026-11-07 用户确认「开始」，按 M1–M4 实施。

## 0. 目标

P0/P1 解决「能验收、不重复」；P2 解决「验收什么、凭什么验收、变更怎么留痕」。
核心：给玉简加一个 agent 一读就懂的**契约视图**，和一个结构化的**提交对象**。

## 1. 从「工作流优化专项 1」提取的 5 个结构性问题

| # | 现象 | 缺的东西 |
|---|---|---|
| 1 | body 仍写「只需要出详细的改动方案」，实际做完了实现 | 没有「当前契约版本」，范围漂移只在聊天里 |
| 2 | 6 个 item 全是问题句，整条 done_when 为空 | 没有「这一项怎样算完成」 |
| 3 | 4 条用户拍板值由 agent 转述、重复贴在 2 项上、作者是 UUID | 决定不是人本人记的一等公民 |
| 4 | 12:25「实现完成，提交等验收」只是一句留言；报告改了 5 版；「v1 明确未做」不在玉简上 | 提交没有结构，看不出验收的是哪一版、哪些没做 |
| 5 | 12:25 留言写「未提交、未合并」，后来提交了，旧留言还在 | 结论会过期，没有「当前结论」 |

## 2. 数据模型（全部新字段可选，旧 JSON 原样可读）

沿用：空则省略、主机 `Value` 级读写不定义强类型、不擦未知字段。

### 顶层
| 字段 | 类型 | 谁写 | 说明 |
|---|---|---|---|
| `contract_version` | int，缺省 1 | 人 | 改 goal/body/constraints/done_when 或新增决定时 +1，记 `contract_changed` 事件 |
| `decisions[]` | `{id, text, decided_by, decided_at, source_channel_id, item_ids[], supersedes?}` | 人 | 身份取执行上下文，不接受 agent 自报 `--by user` |
| `current_conclusion` | `{text, by, at, evidence[], submission_rev}` 或 null | 人/She | 覆盖式，不是追加 |

### item 级
| 字段 | 类型 | 谁写 | 说明 |
|---|---|---|---|
| `acceptance` | `{criteria[], verify[], confirmed_by, confirmed_at}` | agent 提议 / 人确认 | 这一项怎样算完成 |
| `submission` | 见下 | agent | 每项的当前提交，rev 自增 |
| `gaps[]` | `[{id, text, child_slip_id?}]` | agent 提 / 人转 | 「明确未做」的落点 |
| `state` | 增加 `cancelled` | 人 | 「不做了」 |

`submission`:
```json
{
  "rev": 3,
  "summary": "P4 主机+App 已完成…",
  "changed": ["crates/flow/src/def.rs", "lib/screens/flow_run_screen.dart"],
  "verify": ["cargo test --workspace 全绿", "flutter test 3745 passed"],
  "gaps": ["真机联调未做", "agent_chunk 无 durable 回放"],
  "code_refs": [{"repo":"shepaw-cli","branch":"worktree-flow-opt-host","commit":"af129ef"}],
  "evidence": [{"uri":"pouch://…/实现结果.md","version":26781,"hash":"…","size":10544,"label":"实现结果"}],
  "submitted_by": "fb1d3f94…",
  "session_id": "dm_…",
  "submitted_at": 1794004573341,
  "supersedes_rev": 2
}
```

### 证据升级（不改存储）
`evidence` 从 `string[]` 升为 `string[] | object[]` 双读；新写用 `slip evidence` 从 `pouch.meta()` 取 `version/hash/size/mtime_ms`；同 `uri+version` 去重；同 URI 不同 version = 不同证据，UI 显示 `实现结果.md · v26781`。**不改写旧字符串证据**，只在视图层归一化。

### comment / event
- `comment.kind`: `progress|decision|risk|note`（缺省 progress）；`supersedes` 指向旧留言 id。
- 新 event kind：`decision`、`acceptance_proposed`、`acceptance_confirmed`、`submission_replaced`、`conclusion_changed`、`cancelled`、`gap_split`、`contract_changed`。
- 事件只记状态变化，不记正文；正文在结构字段里。

## 3. 状态机

```
open ──submit(带 summary)──> submitted ──accept──> accepted
  │                              │  └──return(原因)──> open
  │                              └──submit(rev+1)──> submitted  [撤销旧验收]
  ├─block──> blocked ──unblock──> open
  ├─propose-acceptance──> open(待确认) ──confirm──> open
  └─cancel(人,带原因)──> cancelled
```

优先级（两端必须完全一致，用同一份向量表测试）：
1. 全部项 ∈ {accepted, cancelled} 且每个 cancelled 有非空 `cancelled_reason` → `done`
2. 任意 blocked → `blocked`
3. 有 open → `in_progress`（若存在非 open）/ `open`
4. 有 submitted → `needs_review`
5. 有 cancelled → `in_progress`
6. 否则 `open`
archived 保持；空清单保持原状态。

已拍板默认值：
- `cancelled` **计入 done，但 UI 单列「取消 N 项」**
- 新 `rev` **自动撤销已验收**（accepted → submitted，事件 `submission_replaced`）
- 验收标准 **不强制**填写，派发时提醒 + 待验收视图并排显示
- 提交 **必须带 `--summary`**，空则拒绝（旧命令走兼容默认 summary）
- 旧数据 **不自动迁移**，`slip migrate` 显式跑

## 4. CLI 与权限矩阵

| 命令 | 人/She | Agent |
|---|---|---|
| `slip submit --id --item --summary "…" [--verify …] [--gap …] [--code …] [--evidence …]` | ✓ | ✓ |
| `slip evidence --id --item --uri …` | ✓ | ✓ |
| `slip propose-acceptance --id --item --criteria "…"` | ✓ | ✓ |
| `slip confirm-acceptance --id --item` | ✓ | ✗ |
| `slip decide --id --text "…" [--items a,b]` | ✓ | ✗ |
| `slip conclude --id --text "…" [--evidence …]` | ✓ | ✗ |
| `slip cancel --id --item --reason "…"` | ✓ | ✗ |
| `slip gap --id --item --title "…"` | ✓ | ✗ |
| `slip migrate --id` | ✓ | ✗ |
| `slip get --since <ms> [--limit-events N]` | ✓ | ✓ |

保留全部旧命令别名：`item --done true`、`item --evidence`、`complete` 内部转成新结构并给 deprecation 提示，已有 agent 脚本不失效。

`slip get` 缺省返回**契约视图**：goal/constraints/done_when/contract_version/current_conclusion/decisions + 每项的 acceptance.criteria / 最近一次 submission 的 summary+rev / 退回原因 / gaps 数。`--full` 返回全文。

## 5. App UI

| 位置 | 改动 |
|---|---|
| 编辑页顶部 | 「当前结论」卡片：有则显示、覆盖式、带 by/时间/证据 |
| 新增「决定」区 | 时间线，标注谁确认、影响哪几项、contract_version |
| 清单项展开 | 验收标准 / 提交卡（rev、改了什么、怎么验、gaps、代码位置、证据 vN）/ 退回原因 |
| 待验收视图 | 左右对照「验收标准 ↔ 本次提交」，一键「通过 / 退回（带原因）」 |
| gaps | 每条一键转子简（复用 `_splitItem` 链路） |
| 动态区 | 保留 P1 分组折叠，点击可展开结构化对象；`submission_replaced` 显示 rev 变化 |
| 列表 | 显示 rev / 待验收数 / 取消数 |
| 派发弹层 | 提示 goal + done_when + 每项 acceptance 是否填了（提醒不强制） |

P2 需要新增 UI 文案，动 `app_zh.arb` + 重新生成 `app_localizations.dart`。

## 6. 工程前提：先修并发写

`save()` 用 `ExpectedVersion::Exact`，但 `read_slip → mutate → save` 之间有窗口。M1 收敛所有写命令到
`mutate_slip(pouch, device, id, actor, session, f)`：read → f → save，冲突重读重试 2–3 次，仍失败返回明确错误，不静默覆盖。

## 7. 兼容与迁移

- 新字段全可选；`fromJson` 容忍缺失；`toJson` 空则省略。
- 主机继续 `Value` 级读写；`normalize_items` 只做 evidence 去重与 state/done 归一，不改写 evidence 形态。
- `slip migrate --id` 显式执行一次：38 条重复证据 → 3 个 URI × 5 个 version 的结构化对象；22 条重复留言按 `(text, created_at)` 合并、保留最早 id、其余标 `supersedes`；过时留言标 `superseded_by`；4 条拍板值抽成 `decisions`；body 的「只出方案」记 `contract_changed`，`contract_version=2`。
- **HARD RULE：实现 migrate 但绝不对真实玉简 `a7a560d1-0674-4938-8657-3446248844af` 执行**，只在测试袋子里用合成数据验证。

## 8. 里程碑

| | 内容 | 主要文件 |
|---|---|---|
| M1 | 主机：mutate_slip CAS、新字段、7 个新命令、契约视图、状态向量表、8+ 用例 | `crates/api/src/slips.rs`、`she_tools.rs`、`cli/src/main.rs`、`she/src/{tools,prompt}.rs` |
| M2 | App 模型：4 个新类、cancelled、双读兼容、service 方法 | `lib/models/jade_slip.dart`、`lib/services/jade_slip_service.dart`、`test/models/` |
| M3 | App UI：结论卡、决定区、提交卡、待验收对照、gaps 转子简、证据 vN、ARB | `lib/screens/jade_slip_*.dart`、`lib/l10n/` |
| M4 | 文档 + migrate + 真机联调 | `SKILL.md`、`she_service.dart`、`group_context_builder.dart` |

## 9. 验收标准

1. 重放同一条玉简：一次 submit → 一次 accept → done，新增事件 ≤ 3 条。
2. 报告连改 5 版后 `slip get` 显示 rev=5，5 个证据 version/hash 可点开，旧验收自动作废。
3. 4 条拍板值出现在 decisions，`decided_by=user`，contract_version=2。
4. current_conclusion 更新后 UI 只显示最新结论。
5. 两个 agent 并发 submit 同一项不丢更新（CAS 用例）。
6. 旧 JSON 全量回归：主机 ≥383 passed、App ≥33 passed、状态向量表两端一致。
7. 真机：App 派发 → agent submit → 人通过 → 两端同步。

## 10. 明确不做

不换存储、不引入新文件类型；不自动验收、不允许 agent 自评或自报 `decided_by=user`；不改派发链路、不改 pouch 布局；不做跨玉简搜索/聚合；不自动清理旧数据。

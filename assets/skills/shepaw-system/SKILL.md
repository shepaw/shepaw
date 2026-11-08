---
name: ShePaw System
description: 当需要调用 ShePaw 的命令、读写储物袋或玉简、或不确定某个命名空间怎么用时，读取本技能。它只讲约定和发现方式，子命令以 shepaw <命名空间> 的输出为准。
---

# ShePaw 系统技能

阅读对象：本地 LLM、Hub 引擎、以及经 ACP 接入的外界 Agent。本技能不是应用使用指南。

## 发现命令

不要凭记忆编参数。

1. `shepaw help` 列出命名空间。
2. `shepaw <命名空间>` 不加子命令，列出该命名空间的子命令。
3. 某个子命令加 `--help`，或在工具调用里传 `flags={"help":""}`，看用法。

ACP 上没有 `shepaw` 工具时，用 `hub.cli.execute`，`namespace` 填下面同一个名字。不要传 `agent_id`、`owner`、`channel_id`。

Hub 引擎打本机 PATH 上的 `shepaw`。玉简、技能、储物袋都在主机本地执行；`shepaw slip` 不再转发给 App，也不要用 `hub.cli.execute`。

## 储物袋

URI 是 `pouch://<space>/<device_id>/<path>`。看到它就用 `pouch read` / `list` / `search`。不要用 `os.file`，不要自己编地址。写完文件后，引用命令返回的那条 URI。

能进储物袋的，不要写到本机任意路径。五个分区各管一件事：

### cognition 认知

这个 Agent 的 soul 和结构化记忆。权威是 `soul.md` 和 `entries/`。

- 读 scope card 上的认知地址。
- 写入走 `shepaw context` 的 memory / soul 子命令。不要 `pouch write`。
- 简历是 `pouch://cognition/<device>/<agentId>/resume.md`，和 `soul.md` 并列。用 `pouch read` / `pouch write` 读写这一份。不要写到 `files`。
- `runtime/.../soul.md` 和 `memory.md` 只是镜像，禁止回写。
- 群任务没有个人认知袋。

### runtime 运行时

这一轮的会话现场：会话记录、附件，以及本轮产物。

- 产物在 `runtime/<device>/<owner>/<channel>/artifacts/<task>/<file>`。
- `pouch write` 不带 `--space` 时默认落在这里。
- 旧分区 `pouch://artifacts/...` 只用来读历史，不要再写。

### workspaces 工作区

已经挂上的项目目录，以及群里要跨设备留下的文件。

- scope card 写了工作区地址时，读写那个 URI。
- 群成员留下共享文件：`pouch write --space workspaces --group <群id>`，落到自己的 `members/<agentId>/`。群上下文里不带 `--space` 时，也会尽量走这条。

### tools 工具

App 和各智能体的 MCP、规则、技能。先读这里，再决定怎么做。

- App：`mcp/<name>/`、`rules/<name>/`、`skills/<name>/SKILL.md`
- 某个智能体：`agents/<agentId>/mcp`、`rules`、`skills`
- 本技能在 `skills/shepaw-system/SKILL.md`。

### 其余

- `files`：用户自己的文件。不要把 Agent 简历、灵魂或记忆写到这里。
- `public`：用途未定，不要写入。
- 玉简在 `slip:<id>` scope。用 `slip` 改，不要 `pouch write` 覆盖那份 JSON。

## 玉简

玉简是人和 Agent 之间这一次的工作契约，不是聊天记录，也不是 Agent 的记忆。

- 目标、约束、完成标准写在简上。
- `slip item --done true` 表示已提交，等人验收；验收通过才算完成。`slip accept`、`slip item --return --reason "..."` 只有人或 She 能用。
- 写命令默认只返回 brief 摘要（action / status / updated_at 等）。看全文用 `slip get --id <id>`，或给写命令加 `--full`。
- 一次给多项写同一条汇报用 `slip report --id <id> --items <id1,id2> --text "..." [--evidence <uri>]`；证据 URI 自动去重，动态只记一条。
- 提交用 `slip submit --id <id> --item <itemId> --summary "改了什么" [--verify ...] [--gap ...] [--code ...]`：**必须带 summary**。每次提交 rev+1；若该项已验收，新 rev 会自动作废旧验收，要重新验收。
- 证据用 `slip evidence --id <id> --item <itemId> --uri <pouch-uri>`：会记下 pouch 的 version/hash，界面显示 `名称 · vN`；同一 `(uri, version)` 不重复挂。旧的裸 URI 证据仍可读，但不要再写。
- 验收标准：`slip propose-acceptance --criteria "..."` 由 Agent 提议，**只有人能用 `slip confirm-acceptance` 确认**。
- 人拍板用 `slip decide --text "..."`（contract_version +1）；`slip conclude --text "..."` 覆盖「当前结论」（不追加，旧结论不再误导）；`slip cancel --item --reason` 标「不做了」；`slip gap --item --title` 把未做项拆成子简。这几个只有人或 She 能用，Agent 不要自报 decided_by。
- `slip get --contract` 返回精简契约视图（目标/约束/完成标准/决定/当前结论/每项验收标准与最近提交）；`--since <ms>` / `--limit-events N` 可截断时间线；`--full` 看全文。
- `slip migrate --id` 只在人显式执行时去重旧证据/重复留言，**不会对任何玉简自动跑**。
- 一项可以交给另一个 Agent。
- 子命令以 `shepaw slip` 为准。
- 储物袋里的玉简是 `pouch://<pouch_id>/slip:<id>/slip.json`，文件里 `kind` 为 `jade_slip`。读到它就是一条玉简。
- 进度、验收、证据用 `shepaw slip` 写回。不要用 `pouch write` 覆盖这份 JSON。

用户要你做待办、勾进度、或说「记到玉简」时，用 `slip`，不要只在对话里答应。

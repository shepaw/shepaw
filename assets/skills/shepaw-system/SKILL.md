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

Hub 引擎打本机 PATH 上的 `shepaw`。本机 device 的储物袋留在 Hub；`slip`、`skills` 以及其他命名空间转到配对的 App。不要用 `hub.cli.execute`。

## 储物袋

URI 是 `store://<space>/<device_id>/<path>`。看到它就用 `store read` / `list` / `search`。不要用 `os.file`，不要自己编地址。写完文件后，引用命令返回的那条 URI。

能进储物袋的，不要写到本机任意路径。五个分区各管一件事：

### cognition 认知

这个 Agent 的 soul 和结构化记忆。权威是 `soul.md` 和 `entries/`。

- 读 scope card 上的认知地址。
- 写入走 `shepaw context` 的 memory / soul 子命令。不要 `store write`。
- `runtime/.../soul.md` 和 `memory.md` 只是镜像，禁止回写。
- 群任务没有个人认知袋。

### runtime 运行时

这一轮的会话现场：会话记录、附件，以及本轮产物。

- 产物在 `runtime/<device>/<owner>/<channel>/artifacts/<task>/<file>`。
- `store write` 不带 `--space` 时默认落在这里。
- 旧分区 `store://artifacts/...` 只用来读历史，不要再写。

### workspaces 工作区

已经挂上的项目目录，以及群里要跨设备留下的文件。

- scope card 写了工作区地址时，读写那个 URI。
- 群成员留下共享文件：`store write --space workspaces --group <群id>`，落到自己的 `members/<agentId>/`。群上下文里不带 `--space` 时，也会尽量走这条。

### tools 工具

App 和各智能体的 MCP、规则、技能。先读这里，再决定怎么做。

- App：`mcp/<name>/`、`rules/<name>/`、`skills/<name>/SKILL.md`
- 某个智能体：`agents/<agentId>/mcp`、`rules`、`skills`
- 本技能在 `skills/shepaw-system/SKILL.md`。

### 其余

- `files`：用户自己的文件。简历在 `files/<device>/<agentId>/resume.md`。
- `public`：用途未定，不要写入。
- 玉简在 `slips`。用 `slip` 改，不要 `store write` 覆盖那份 JSON。

## 玉简

玉简是人和 Agent 之间这一次的工作契约，不是聊天记录，也不是 Agent 的记忆。

- 目标、约束、完成标准写在简上。
- 勾选一项表示已提交，等人验收。验收通过才算完成。
- 做完的产物用 `slip item --evidence` 挂回对应项。
- 一项可以交给另一个 Agent。
- 子命令以 `shepaw slip` 为准。
- 储物袋里的玉简是 `store://slips/<device>/<id>.json`，文件里 `kind` 为 `jade_slip`。读到它就是一条玉简。
- 进度、验收、证据用 `shepaw slip` 写回。不要用 `store write` 覆盖这份 JSON。

用户要你做待办、勾进度、或说「记到玉简」时，用 `slip`，不要只在对话里答应。

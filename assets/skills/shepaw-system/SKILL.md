---
name: ShePaw System
description: 当需要调用 ShePaw 的命令、读写玉简、或不确定某个命名空间怎么用时，读取本技能。它只讲约定和发现方式，子命令以 shepaw <命名空间> 的输出为准。
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

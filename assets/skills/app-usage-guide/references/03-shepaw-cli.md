## 3. 工具能力层（She 自己的工具——ShePaw CLI）

She 与其他 Agent 通过 `shepaw <namespace> <subcommand> [--flag value ...]` 工具树读写本地数据。这是「她知道有哪些工具」的基础。

**通用用法：**

- `shepaw help` → 列出所有命名空间；
- `shepaw <namespace>` → 列出该命名空间的子命令；
- 点分嵌套：`shepaw context profile.query`；
- 任意命令带 `flags={"help": ""}` → 查看详细用法与 flags。

**命名空间分层：**

```
🧠 CONTEXT 层    context    档案 / 记忆 / AI 助手（profile.* / memory.* / agents.*）
💬 COMMUNICATION chat       对话频道与消息（channels / messages / message.get / group.*）
🔧 TOOLING 层    tools      系统工具（network.* / web.*：web.search / web.fetch / web.config）
                skills     已加载的 LLM 技能库（list / detail）
                os         直接操作系统工具（command / file / app / clipboard / process / macos）
                workflow   工作流编排（create / dispatch / status / complete / fail / cancel）
                store      储物袋 store:// 读写（write / read / list）
ℹ️ META 层       meta       系统信息与时间（datetime；system.info / system.tools-list /
                           system.tools-detail / system.capabilities；cli-tools 外部工具管理）
                help       顶层帮助
🔌 EXTERNAL 层   <namespace>  从 ~/shepaw/cli-tools/ 动态加载的外部工具
```

**关键子命令速查：**

| 命名空间 | 常用命令 |
|---------|---------|
| `context` | `profile.query/write/delete` · `memory.query/write/append` · `agents.list/get/channels/messages/chat/memory-query/memory-write/cognition-query/cognition-write/resume-get/resume-set/dispatch` |
| `chat` | `channels`（列频道）· `messages --channel <id>`（查消息）· `message.get --id <mid>`（读完整消息/附件/图片分析）· `group.create/add/kick/rename/set-bio/set-description/send` |
| `tools` | `web.search --query ... --limit ...` · `web.fetch --url ...` · `web.config` · `network.*` |
| `skills` | `list` · `detail --name <skill>`（读技能全文） |
| `os` | `file.*` · `command.*` · `app.*` · `clipboard.*` · `process.*`（平台相关） |
| `workflow` | `create` · `dispatch` · `status` · `complete` · `fail` · `cancel`（群 Admin 或 She 1:1 DM） |
| `store` | `write --filename <name> --content <text> [--task] [--space public/workspaces --group <gid>]` · `read --uri <store://...>` · `list --uri <store://...> --depth 1` |
| `meta` | `datetime` · `system.info` · `system.tools-list` · `system.tools-detail --name <tool>` · `system.capabilities` · `cli-tools.list/install/uninstall/rescan` |

**使用纪律：**

1. 看到 `store://…` 一律用 `shepaw store read/list`，**不要**用 `os.file.read` 去读。
2. 产物优先 `shepaw store write`（拿到可分享的 URI），不要用 `os.file.write` 写报告/代码/文档。
3. 群聊执行上下文里 `store write` 默认落到**群工作空间成员目录**（`members/<agentId>/`，跨设备可见），不是本地私有 runtime。
4. 命令执行有**权限检查**（`CliCommandConfigService`）：UI 操作跳过；Agent 主动调用按配置放行或拒绝。
5. 读聊天记录里历史图片：`shepaw chat message.get --id <message_id> --analyze "<问题>"`（图片是元数据，不会自动进上下文）。

# ACP 空闲超时：分阶段预算 + 在途工具宽限 + 优雅收尾

状态：轮 1-3 已落地，轮 4 不做（理由见文末）
范围：`shepaw-cli/crates/engines/src/stdio.rs`（主机侧）。App 侧没改。
相关：docs/acp_network_switch_resilience_decision.md（App 侧重连/续传，已落地）

## 实测结论（CodeBuddy 真实帧，2026-10-14 抓）

用 `codebuddy --acp` 跑一次 `sleep 20` 抓到的完整帧序（时间戳为秒）：

```
 5.99 tool_call          toolCallId=chatcmpl-tool-8c4e  status=in_progress  title=Bash
 6.27 session_info_update agentPhase=waiting_for_permission
 6.48 session_info_update agentPhase=tool_executing          ← 命令开始跑
 6.51 usage_update                                            ← 之后一条帧都没有
26.54 session_info_update agentPhase=model_requesting        ← 20 秒静默结束
29.98 agent_message_chunk
```

三条关键事实：

1. 工具执行期间**一条帧都不发**，静默 20 秒（换成构建就是几分钟）；
2. `tool_call_update` 只在**流式吐工具入参**时出现，且**不带 `status`**；
3. 跑完**没有 `tool_call_update(status: completed)`**，唯一的收尾信号是
   `agentPhase` 切回 `model_requesting` —— 这正是原来 120 秒必杀的那一段。

## 背景

用户和 CodeBuddy 实例对话时收到：

```
Error: Failed to send message to shepaw. Details: Exception: ACP 空闲超时
```

错误源是主机侧 `stdio.rs:994`：读子进程 stdout 的循环里，距上次「算进度的行」超过
`idle_limit()`（`SHEPAW_ACP_IDLE_SECS`，**默认 120s**）就 `kill_tree()` 并返回
`Err("ACP 空闲超时")`。App 在 `agent_messaging_service.dart:744` 把它拼成上面的文案。

## 现状

- 「算进度」的行（`line_marks_progress` `stdio.rs:1347` + `update_marks_progress` `:1330`）：
  带 `id` 的 JSON-RPC 响应/请求；或 `session/update` 且 `sessionUpdate` ∈
  `{agent_message_chunk, agent_thought_chunk, user_message_chunk, tool_call, tool_call_update, plan}`。
  其它（available_commands_update、mode/config 更新、stderr）都不算。
- 三个阈值：`SHEPAW_ACP_IDLE_SECS` 120s、`SHEPAW_ACP_TURN_SECS` 30min、`SHEPAW_ACP_CANCEL_SECS` 10s。
- 超时即 `kill -KILL -PID`（`kill_tree` `:1029`），子进程树没了，缓存的 session id 失效。
- 「优雅取消」已有实现，但只在用户点停止时用：`cancel()` 先写 `session/cancel` 再置
  `cancel_at = now + cancel_grace`（`:186`），`read()` 到期才 kill（`:989`）。
  idle / turn 超时**没有走这条路**，直接 SIGKILL。
- 审批等待有补偿（`credit_wait` `:931`/`:1018`），不计入 idle，这块没问题。

## 根因

**单一 120s 静默阈值，把三种完全不同的状态混为一谈：**

| 状态 | 典型场景 | 120s 判死是否合理 |
| --- | --- | --- |
| A 子进程真死了 / 挂住 | 崩溃、等 stdin、被系统冻结、切网后模型请求黑洞 | 合理，甚至嫌慢 |
| B 启动握手慢 | `initialize` / `session/new` / `session/load` 时登录态失效、冷启动、MCP 连不上 | 阈值相同但语义不同，错误文案完全误导 |
| C 工具在跑但不吐帧 | 长构建 / 测试 / 安装 / 长 bash，期间没有 `tool_call_update` | **不合理** —— 这是最常踩的一种 |

C 是主因：工具已经开始（`tool_call` 帧到达，此时 `last_line` 被刷新一次），之后一路静默到
120s 就被杀。而工具跑 3 分钟是常态，跑 10 分钟也不算异常。

## 目标

- C 类不再被误杀：工具在跑、没有输出，也能撑到它跑完（或撑到一个合理的长上限）。
- A 类仍然快速判死：真死的时候不要从 120s 拖到 15min。
- B 类有独立预算和可辨识的错误文案。
- 超时收尾不留脏状态、不 SIGKILL 了事，且**能救回已经吐出来的正文**。
- 错误信息能指导下一步动作，而不是一句「ACP 空闲超时」。

非目标：

- 不改 ACP 协议、不改 App 侧 peer 逻辑。
- 不做「探测子进程是否存活」这类 OS 层 hack（子进程活着 ≠ 在干活，探不到有用信息）。

## 方案

### 轮 1：在途工具宽限（解决 C，收益最大）

1. 在 `read()` / `request()` 处理 `session/update` 的地方（`stdio.rs:934-956`，那里拿得到
   `&mut self`）维护一个 `tool_in_flight: bool`：
   - `sessionUpdate == "tool_call"` → 置 true（记录 `toolCallId`）；
   - `tool_call_update` 且 `status` ∈ `{completed, failed, cancelled}` → 置 false；
   - 收到 `agent_message_chunk` / `agent_thought_chunk` → 置 false（模型又开始说话，说明上一个工具已收尾）。
2. idle 判定改用分档阈值：`tool_in_flight` 为真时用 `SHEPAW_ACP_TOOL_IDLE_SECS`
   （**默认 900s / 15min**），否则用现有 120s。两档都仍受 `turn_limit`（30min）约束。
3. **降级策略**：若实测发现 CodeBuddy 的 `tool_call_update` 不带 `status` 字段（待确认，见
   「待实测」），则退化为「`tool_call` 之后的第一个非 tool 帧即视为工具结束」——即只有
   `tool_call` → 立即静默这一段的窗口被放宽，语义仍然成立。

### 轮 2：超时先 cancel 再 kill（优雅收尾 + 顺带 liveness 探测 + 救回正文）

把 idle / turn 超时从「直接 `kill_tree()`」改成复用已有取消路径：

1. 超时触发时，若还没 cancel 过：发一次 `session/cancel`，置 `cancel_at = now + cancel_grace`（10s），
   **不立即返回错误**，让 `read()` 继续跑。
2. 这段 grace 期内：
   - 子进程若还活着且事件循环正常 → 会回 `end_turn`，可能带上已生成的正文 → **按成功收口**
     （复用 `TurnEnd::Finished`，`full` 已在累积 `:853`）；
   - 子进程若已假死 → 不会回任何东西，`cancel_at` 到期走现有分支 kill，报错
     「ACP 取消后进程未退出」。
3. grace 到期仍未退出 → kill（与现在一致）。

这一条同时白拿三样东西：优雅退出、零成本的 liveness 探测（不额外发明心跳协议）、
有机会把已有正文作为部分结果返回而不是整回合判失败。

### 轮 3：分阶段 + 可读错误（解决 B 和「看不懂」）

（落地时省略了握手独立阈值，见文末「落地情况」）

1. `request()` 已有 `waiting_for` 参数（`:904`），据此区分阶段：
   handshake（`initialize` / `session/new` / `session/load` / `session/set_*`）与 turn。
   给 handshake 一个独立阈值 `SHEPAW_ACP_HANDSHAKE_IDLE_SECS`（默认 120s，与现在一致，
   但错误文案不同）。**不建议**把 handshake 阈值调大：握手阶段静默基本等价于「起不来」，
   让用户早点知道更好。
2. 错误文案带上阶段、静默时长、最后一次进度类型、建议动作，例如：
   > CodeBuddy 静默 2 分钟后被停止（阶段：回复中；最后一次输出：tool_call「Shell」）。
   > 若任务本身需要更久，可在主机环境调大 `SHEPAW_ACP_TOOL_IDLE_SECS`。
   handshake 阶段则提示「检查 `codebuddy` 能否在终端正常启动 / 是否已登录」。
3. 主机侧 `tracing` 打一条带 `engine / session_key / phase / idle_secs / last_update_kind` 的结构化日志，
   方便事后定位。

### 轮 4（可选）：per-agent 覆盖

全局环境变量粒度太粗（cursor / codebuddy / qoder 静默特性不同）。可在 engine spec 或
`agent.metadata` 上加 `idle_secs` 覆盖，优先级：agent 覆盖 > 环境变量 > 内置默认。
本轮不做，等轮 1-3 跑顺再说。

## 取舍

- **不把全局默认值直接调大到 15min**：那样 A 类（真死）要等 15 分钟才报错，体验更差。
  分档是为了只放宽「有证据表明它在干活」的那一段。
- **不用「子进程还活着就不算超时」**：`kill -0` / 探测 pid 只能证明进程没死，证明不了在干活，
  会把真死拖到 turn 上限。用 `session/cancel` 的响应做 liveness 信号才是有语义的探测。
- **15min 上限仍然受 30min 回合上限约束**：工具跑超过 30min 的，应当显式调
  `SHEPAW_ACP_TURN_SECS`，而不是悄悄改 idle。
- **grace 期内拿到正文就当成功**：可能交出一条被截断的回复。相比「整回合报个看不懂的错」，
  截断但可用的正文更有价值；且 cancel 本来就是我们要终止它，语义自洽。

## 验收

- 单元测试（fake agent 起 `node -e`，预算用 `SessionPool::with_limits` 注入毫秒级，
  所以整套测试 2 秒跑完而不是等 15 分钟）：
  1. `tool_signal_follows_the_frames_codebuddy_actually_sends` —— 直接钉住上面抓到的
     那几种帧（含不带 `status` 的 `tool_call_update` 走降级、phase 进出）；
  2. `silent_tool_call_survives_the_plain_idle_limit` —— `tool_call` 后静默（> idle、
     < tool_idle）→ 正常收口；
  3. `silence_without_a_tool_still_fails` —— 没有工具的静默照旧判死；
  4. `timeout_cancels_first_and_keeps_the_partial_reply` —— 超时先发 cancel，引擎回
     `end_turn` → 交出部分正文；
  5. `a_stalled_handshake_points_at_the_engine_not_the_timeout` —— 卡在 `session/new`
     的报错指向终端/登录。
- 手工（未做，建议发布前跑一次）：让 CodeBuddy 跑一个 3-5 分钟无输出的长命令
  （如 `npm install` / 大仓全量测试），确认不再被杀；再 `kill -STOP` 子进程模拟假死，
  确认 2 分钟内报错并解卡。

### 轮 5：让引擎自己说（超时 cancel 的 grace 要够）

用户裁定：**超时之后不要我们替它写结论，要让引擎自己把话说完**。

「回给 Agent」有个硬约束：ACP 没有往在途回合里塞话的口子，唯一入口是
`session/prompt`，而对端此时已经静默很久了。所以只能在两条路上实现：

- **引擎还活着**（工具慢，事件循环正常）—— 这是我们真正想要覆盖的场景。
  `session/cancel` 它收得到，会自己中断工具、回 `end_turn`，正文里说什么由它决定。
  要做的是**给它足够的时间把这句话说完**：
  1. 超时场景的 grace 从 `cancel_grace`（10s，与用户点停止共用）里拆出来，
     单独一个 `SHEPAW_ACP_TIMEOUT_GRACE_SECS`，默认 60s。中断一条真在跑的
     bash（kill 子进程树、收尾、再让模型生成一句回复）10 秒不够。
  2. grace 期间它每吐一帧就把硬 deadline 往后推一个 grace：它还在动就继续等，
     彻底不动了才 kill。否则会出现「它正在组织回复、被我们在半句上掐死」。
  3. 回合总时长上限照旧兜底，不会被无限续命。
- **引擎真死了 / 卡死** —— 回不去，收不到任何东西。仍然只报我们自己的文案（轮 3）。
  不做「kill 后重开会话再喂一轮 prompt」：15 分钟静默区分不了「工具在跑」和
  「工具卡死」，对卡死的情形再让用户等一轮模型调用是雪上加霜，还会盖住
  「这条命令其实卡住了」这件更该被看见的事。

## 让引擎自己控制这个超时（方案 1，已落地）

**实测否掉一条**：想读引擎给命令设的 `timeout`（bash 工具的入参）来反推预算 ——
不可靠。`tool_call` 帧里的 `rawInput` 常常是空的（2026-10-14 抓到的一次
`sleep 40` 全程只有一个 `rawInput: {}` 的 `tool_call`，没有第二条带完整入参的），
而且即使有也未必带 `timeout`。这条路不能依赖。

剩下三条，代价差很多：

1. **让引擎自己规避（已落地）** —— 每轮 prompt 前带一句
   「预计超过 N 分钟的命令尽量用后台跑，并先告诉用户要等多久」，N 由
   `SHEPAW_ACP_TOOL_IDLE_SECS` 换算（默认 15 分钟），两个数字同源。
   命令不阻塞回合就不会静默，超时根本不会触发；用户等待期间还能继续对话。

   **实测有效**（2026-10-14）：把工具静默上限压到 25 秒（提示里的 N 随之变成
   1 分钟后），让 CodeBuddy 跑 `sleep 300`，它的思考是
   "Per instructions, long-running commands (>1 min) should be run in background"，
   然后真的放后台、回复「预计耗时 5 分钟，已放到后台跑。」，回合 35 秒正常收口，
   全程没触发超时。
2. **让引擎显式申请** —— 约定一个 `_meta` 字段（如 `shepaw.ai/idleSecs`）或
   暴露一个内部工具 `shepaw_extend_idle(seconds)`，引擎开工前调一次我们就改预算。
   这是真正意义上的「引擎自己控制」。代价：前者需要引擎配合（CodeBuddy 不是
   我们的，做不到）；后者要动 gate 放行 + 在系统提示里教它 + 截获这个 tool_call。
3. **环境变量**（现状）—— 只有主机级，per-agent 做不到（见轮 4）。

## 落地情况

| 轮 | 内容 | 状态 |
| --- | --- | --- |
| 1 | 在途工具宽限（`tool_signal` + `SHEPAW_ACP_TOOL_IDLE_SECS` 默认 900s） | 已落地 |
| 2 | 超时先 `session/cancel` 再 kill + 救回部分正文 | 已落地 |
| 3 | 分阶段文案 + `tracing::warn` | 已落地 |
| 5 | 超时 grace 单独给（60s）+ grace 内有输出就续期 | 已落地 |
| 6 | 超时后让引擎自己说（补一轮 prompt，默认开） | 已落地 |
| 7 | 提示引擎把久命令放后台，N 与工具静默上限同源 | 已落地 |
| 4 | per-agent / per-engine 覆盖 | **不做**，理由见下 |

落地时相对方案的两处调整：

- **没有加 `SHEPAW_ACP_HANDSHAKE_IDLE_SECS`**。它与 `SHEPAW_ACP_IDLE_SECS`
  默认值相同，而握手阶段静默恰恰不该放宽，多一个「不建议调大」的旋钮只会误导。
  握手阶段的价值全在文案上，已经做了（轮 3）。
- **`session_info_update` 不算「进度」，只用来判断有没有工具在跑**。
  它是相位变化时才发的，不是心跳；把它当进度会让「卡住但还在报相位」的情况
  永远判不死。静默的语义仍然是「没有输出」。

## 轮 4 为什么不做

- **per-agent**：主机侧拿不到 agent 的配置。`crates/api/src/agent.rs` 调用
  `pool.prompt(...)` 的地方只有 `instance`（引擎、cwd、engine），没有 metadata；
  要把 agent 配置从 store 一路穿到 engines，是跨 crate 的改动。
  而且 `SessionPool::prompt` 已经有 16 个参数，再加一个只会更糟。
- **per-engine**：要给 `EngineSpec` 加字段，就得改 15 处引擎 spec 的字面量构造，
  而现在**没有任何一个引擎有需要不同取值的证据**。

结论：先不做。等真出现「某个引擎/某个 agent 就是需要另一档」时再落，
那时才有取值依据。真要提前留口子，最省的是 per-engine 环境变量
（`SHEPAW_ACP_TOOL_IDLE_SECS_CODEBUDDY` 之类），说一声就能加。

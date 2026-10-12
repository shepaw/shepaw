# ACP 连接抗切网（agent 输出中切换网络不卡死、不中断）

状态：轮 1-3 已落地（根因 1-7 已修），轮 4（HTTP `connectionTimeout`）未做，影响面小
范围：App（`shepaw/lib`）。主机侧（`shepaw-cli`）已有 `idle_limit 120s` / `turn_limit 30min` 兜底，本轮不改。

## 背景

用户反馈：**agent 正在输出（流式吐字）时切换网络（WiFi 换网口、连/断 VPN、移动网络切换），容易卡死**。

ACP 是 App ↔ 远端 agent 的唯一长连（Noise IK + JSON-RPC over WebSocket），流式输出、审批卡、终态全走这一条。切网的典型后果是 TCP「半开」：socket 没收到 FIN，`isConnected` 仍是 true，但收发全不通。

链路（用户发消息 → 流式 → UI）：

| 环节 | 位置 |
| --- | --- |
| UI 发送 | `lib/controllers/chat_controller_messaging.dart:794` |
| 路由 | `lib/services/messaging/agent_messaging_service.dart:671-714` |
| ACP 主路径 | `agent_messaging_service.dart:924 _sendViaACPProtocol` |
| WS 建连 | `lib/services/acp_agent_connection.dart:404-406` |
| 流式回传 | `acp_agent_connection.dart:413` → `agent_messaging_service.dart:1293` → controller `:814` |
| UI 收尾 | `chat_controller_messaging.dart:110 / :857`（`await dbSaveCompleter.future`） |

## 根因（按严重度排序）

1. **建连整条路径没有超时** —— `acp_agent_connection.dart:404` `await io.WebSocket.connect(uri)`、`:406` `await _channel!.ready` 均无超时。切网瞬间 DNS/TCP 挂在失效网卡上，对端黑洞时可**无限挂起**。且 `_getOrCreateACPConnectionWithRetry` 会重试 3 次（`connection_retry_policy.dart:38-45`），一次挂住就是三次挂住。→ **永久卡死**。
2. **切网钩子不覆盖 ACP** —— `lib/services/network_monitor_service.dart:65 _reconnectAll` 只重连隧道和 peer，完全不碰 `_acpConnections`。半开连接只能靠心跳（30s × 3 次失败 ≈ 90-120s）才被发现。
3. **断连即判任务失败** —— `_handleDisconnect()`（`:1519`）和 `disconnect()`（`:743`）无条件 `_failInFlightTasks`。主机上任务其实还在跑（`agent.taskResume` 能续），但 App 直接报 `Connection lost` 结束回合。→ **切网 = 任务中断**，正好是用户说的「影响任务执行」。
4. **`disconnect()` 顺序错误** —— `:743` 的 `_failInFlightTasks` 排在 `:725` `await _channel?.sink.close()` 之后。关闭握手一旦卡住，在跑的任务永远无人解封。（dart:io 有 5s 兜底 timer，但那是尽力而为，不该把解封逻辑挂在它后面。）
5. **停滞看门狗不兜底** —— `stalledTurns()`（`agent_messaging_service.dart:2457`）跳过 `!isConnected` 的任务，`resumeTaskAndDispatch()` 失败后只 log 一行就返回，既不再试也不判失败。断连期间任务完全没人管。
6. **UI 收尾无超时** —— `chat_controller_messaging.dart:111` 和 `:859` 的 `await activeTask.dbSaveCompleter.future` 没有任何超时。任一 finalize 路径漏掉 completing，`isProcessing` 永久 true，`processNextInQueue()` 再也不被调用 → 整个消息队列冻住。
7. **任务默认超时 3 小时** —— `agent_messaging_service.dart:1477`，`task_timeout_seconds` 默认 10800。主机侧回合上限是 30 分钟，App 等 3 小时没有意义。
8. **HTTP 单例无 `connectionTimeout`** —— `channel_mailbox_service.dart` 等长生命周期 `http.Client`，切网后复用旧连接池/DNS 缓存（mailbox 兜底路径，影响面小）。

## 目标

- 切网后**回合能续上**：重连成功就把在跑的任务 resume 回来，接着收剩余输出，用户感觉不到中断。
- 任何情况下**不永久卡死**：建连、关闭、UI 收尾都有上限。
- 续不上时**快速明确失败**：给一句看得懂的错误，UI 解卡。

非目标：

- 主机侧协议改动（`task.resume` 已存在，够用）。
- 多链路冗余（同时走 mailbox 兜底）——本轮只做「重连 + resume」，不做双写。

## 方案

### 轮 1：不卡死（防御底线，不改语义）

1. `ACPAgentConnection.connect()` 整体加超时（DNS + TCP + WS 握手 + Noise 握手，**默认 15s**，构造函数可配）。超时后按可重试错误抛出（`isRetriableConnectionError` 已把 `TimeoutException` 判为可重试），并保证底层 socket 被清理而不是泄漏。
2. `disconnect()` 拆成两步：先解封该解封的东西，再关 socket；`sink.close()` 加 2s 超时，超时直接放弃不再 await。
3. `chat_controller_messaging.dart:111 / :859` 的 `await dbSaveCompleter.future` 加超时（默认 30s），超时后强制 `isProcessing = false` + `processNextInQueue()`。
4. `:1477` 任务默认超时 10800s → 1800s（与主机 `SHEPAW_ACP_TURN_SECS` 对齐），仍可由 `agent.metadata['task_timeout_seconds']` 覆盖。

### 轮 2：切网不断任务（核心价值）

5. **重连宽限期**：断连不再立即 `_failInFlightTasks`。连接进入「reconnecting」态并开一个宽限计时（默认 20s，可配）；宽限期内重连成功 → 对所有未完成任务调 `resumeTaskAndDispatch(taskId, rawStreamLength)` 把输出续回来；宽限期到仍未连上 → 才 fail。
   - `ActiveTask.rawStreamLength` 已经在累积（`:1297`），正好是 resume 需要的 `known_length`。
   - 需要给 UI 一个可选的「正在重连…」提示位，不阻塞。
6. **切网主动探测**：`NetworkMonitorService` 增加 settled hook 注册口；`AgentMessagingService` 注册后，网络稳定时对每个 ACP 连接发一次短超时 ping（5s）：
   - 通 → 什么都不做（不打断正在流的回合）；
   - 不通 → 主动 `disconnect()` + 重建，触发第 5 条的宽限 + resume。

### 轮 3：看门狗兜底（已落地）

7. `resumeTaskAndDispatch()` 计连续失败次数：失败 1 次只记数（可能只是抖动，重连窗口还在跑），连续 2 次才把这个回合判死。收到该任务的真帧时清零。
   `stalledTurns` 保持跳过断连任务（断连由宽限期负责）。

   原计划的「总宽限上限」没做：重连续传想要成功，前提是重连成功且 resume 回
   `streaming`，那说明主机确实还在跑，让它继续是对的；真正会挂死的是「连接看着
   活着但补拉一直失败」，已被上面的失败计数兜住，不必再加一层时间预算。

### 轮 4（未做，影响面小）：mailbox 兜底路径

8. 给 `channel_mailbox_service` 等长生命周期 `http.Client` 补 `connectionTimeout`（10s）。

## 取舍

- **断连先等 20s 再报错**，代价是主机真挂时错误提示晚 20 秒。取这个代价换「切网不掉任务」；宽限时长做成可配，默认 20s（覆盖 WiFi 重关联 + 隧道重建的典型耗时）。
- **不改协议**：完全复用现有 `agent.taskResume`，主机侧零改动。
- **不盲断连接**：切网时不无条件重建 ACP，先 ping。否则每个正在流的回合都会被自己打断，反而更糟。

## 验收

- 单元测试：`connect()` 超时路径、`disconnect()` 在 socket 卡住时仍能解封任务、宽限期内 resume 成功/超时两条分支（`test/services/messaging/`）。
- 手工：agent 长输出中途切 WiFi / 开关 VPN —— 输出停顿后继续，不报错；拔网线超过宽限期 —— 明确报错且 UI 解卡。

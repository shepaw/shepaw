# 元数据缓存与历史游标：审查后的修复清单（2026-10-04）

本文写给负责修复的 agent。审查对象是提交 `3c89c86`（元数据缓存）和 `2d3572b`（会话历史游标），以及 Hub 侧对应的实现。两份方案原文：

- App 元数据缓存：`docs/peer_agent_meta_cache_decision.md`
- 会话历史游标（Hub 和 App 共用）：`shepaw-cli/docs/design/2026-10-04-session-history-cursor.md`，开头"修订"一节列出了这次改了什么

下面按优先级排列。第 1、2、3 项必须修；第 4 项起是可选的小问题。

## 1. 实现元数据方案第 7 节（Hub 配合改动）

现状：`peer_agent_client_service.dart` 里没有 `agent_meta_changed`、`rev`、`not_switchable`，也没有 `metaChanged` 流。Hub 已经实现了这些，在一台设备上改模式、模型、灵魂或命令后会推送给其他设备，App 现在直接丢弃。

按 `peer_agent_meta_cache_decision.md` 第 7 节实现，具体做法如下。

### 1.1 把解析和"完成挂起请求"拆开

`_onModelsResp`、`_onModesResp`、`_onSoulResp` 现在都是"解析 → 写缓存 → 完成 completer"一步做完。拆成两层：

- `PeerModelsList _parseModelsData(Map data)`、`PeerModesList _parseModesData(Map data)`、`PeerSoulInfo _parseSoulData(Map data)`：只解析。
- `_onXxxResp` 调解析函数，写缓存，再完成 completer（逻辑不变）。
- 推送处理只调解析函数和写缓存，**不碰任何 completer**。

`_applyCommandsResp` 末尾会完成 `_pendingCommands`，加一个参数 `completePending`（默认 true），推送时传 false。

灵魂：Hub 推送的 `data` 来自 `read_text`，带 `ok`、`soul`、`editable`、`exists`、`rev`。`exists: false` 时按合法的空灵魂处理（`soul` 为空字符串、`isOk` 为 true），照常写缓存。

### 1.2 `rev` 与"内容没变就不写"

- `_rememberModels`、`_rememberModes`、`_rememberSoul`、`_rememberCommands` 加一个可选参数 `rev`，非空时存进 payload 的 `rev` 键。
- `_writeMeta` 写库前先读已有行：新旧 `rev` 都非空且相等时，**不写库、不发 `metaChanged`**，直接返回。
- `rev` 为空（旧 Hub）时照常写，并发 `metaChanged`。

响应和推送都按这一条处理。

### 1.3 `scope`

`agent_models_resp`、`agent_modes_resp` 和对应推送里的 `data.scope` 不为空、也不等于 `"agent"` 时，不写缓存。Hub 现在只会返回 `"agent"`，这一条是给以后的按会话模式预留的。

### 1.4 `metaChanged` 流

```dart
final _metaChanged = StreamController<({String agentId, String kind})>.broadcast();
Stream<({String agentId, String kind})> get metaChanged => _metaChanged.stream;
```

在 `_writeMeta` 和 `_patchCachedCurrent` 写库**成功之后**发一条，`kind` 用 `PeerAgentMetaKind` 的常量。`forgetPeerAgentMeta` 也发一条，按 `kind` 分别发或约定一个 `'all'` 都可以，选一种写清楚。`stop()` 时不要关闭这个 controller，它是单例的长期流。

### 1.5 推送帧 `agent_meta_changed`

在 `_onControl` 的 `switch` 里加一个 case。帧格式见 Hub 方案 `shepaw-cli/docs/design/2026-10-04-agent-meta-cache.md` 第 4 节：`{type, agent_id, kind, rev, data}`。

| `kind` | 处理 |
| --- | --- |
| `models` | `_parseModelsData(data)` → `_rememberModels(agentId, list, rev: rev)` |
| `modes` | `_parseModesData(data)` → `_rememberModes(...)` |
| `soul` | `_parseSoulData(data)`，`isOk` 才写 |
| `commands` | 解析命令列表 → `_applyCommandsResp(agentId, commands, peerId: event.peerId, completePending: false)`，并把 `rev` 传给 `_rememberCommands` |
| 其他 | 忽略，打 debug 日志 |

`agent_id` 就是本地 agent id（peer agent 的本地 id 等于 remoteAgentId）。

### 1.6 设置失败的错误码

Hub 的 `agent_models_set_resp` / `agent_modes_set_resp` 失败时带 `error`，取值包括 `not_switchable` 和 `unknown_mode`。

- 新增 `Future<({bool ok, String? error})> setModelResult(...)` 和 `setModeResult(...)`，`setModel` / `setMode` 保留原签名，内部调用新函数后只取 `ok`。`_pendingModelSet` / `_pendingModeSet` 的 completer 类型相应改成带 error 的 record。
- `_onModelsSetResp` 收到 `error == 'not_switchable'` 时，把缓存里 models 的 `switchable` 改成 false（仿照 `_patchCachedCurrent` 写一个 `_patchCachedSwitchable`），并发 `metaChanged`。
- `chat_input_area.dart` 的 `_setPeerModel`：改用 `setModelResult`。`not_switchable` 时把 `_peerModelsSwitchable` 置 false，提示 `chat_modelConfiguredOnComputer`，不再提示 `chat_mainModelSwitchFailed`。其他失败沿用现有的回滚和提示。
- `remote_agent_detail_screen.dart` 的 `_onPeerModelSelected` 同样处理。
- `unknown_mode`：沿用现有的回滚和 `chat_sessionModeSwitchFailed` 提示，不改缓存。

### 1.7 界面订阅 `metaChanged`

三个页面在 `initState` 订阅、`dispose` 取消，只处理 `agentId` 等于当前 agent 的事件：

- **`chat_input_area.dart`**：`models` / `modes` 事件到来时重读缓存并 `setState`。用 `_controlsToken` 防止和进行中的刷新互相覆盖；`_modelSetting` 或模式切换进行中时先忽略，等切换完成后的结果为准。
- **`remote_agent_detail_screen.dart`**：`models` / `modes` 重读缓存更新下拉框。`soul` 走现有的 `_applySoul`，它已经按 `_soulApplied` 判断能不能覆盖输入框；不能覆盖时（用户正在改），只提示"已在其他设备修改"。
- **`agent_soul_edit_screen.dart`**：`soul` 事件到来时，输入框内容仍等于 `_initialSoul` 就用 `_presentSoul(..., background: true)` 替换；否则不动输入框，只提示同一条文案。

新增文案：`app_zh.arb` 和 `app_en.arb` 各加一条，键名例如 `agentDetail_soulChangedElsewhere`，中文"已在其他设备修改"。

## 2. 聊天页离线进入后连上设备，模式和模型仍然锁着

现状：`chat_input_area.dart` 的 `_peerControlsOffline` 只在 `_loadAgentControls` → `_showCachedPeerControls` 里设置一次，组件没有监听连接事件。用户离线打开聊天页，设备随后连上（`chat_screen` 会等连接后同步会话），两个入口仍提示"设备离线"，直到退出聊天页再进来。

修法：

- 在 `ChatInputAreaState` 里订阅 `PeerConnectionManager.instance.events`。事件的 `peerId` 等于 `_peerId`，且类型是 `PeerConnectionEventType.connected` 或 `disconnected` 时，调 `unawaited(_loadAgentControls())`。`_loadAgentControls` 自带 `_controlsToken`，重复调用安全。
- `dispose` 里取消订阅。
- `_peerId` 在第一次加载完成前为 null，这时的事件直接忽略即可，加载流程本身会读当前连接状态。

`remote_agent_detail_screen.dart` 也有同样的问题：`_peerLinkUp` 每次 build 时读一次连接状态，但没有任何事件触发重建。照同样的方式订阅，连上时调一次 `_loadPeerModels()`、`_loadPeerModes()`、`_loadSoul()`，断开时 `setState` 一下，让下拉框变成不可用。

## 3. 历史游标：按修订后的方案改

Hub 和 App 都要改，必须**同一批合并**。细节见历史游标方案开头的"修订"一节，以及正文里"游标的含义""`syncHistory` 的流程""重建"三节。App 侧要点：

- 去掉不带 `limit` 的整段请求。`PeerHistoryFetchMode` 改成增量和重建两种。
- 重建模式每页都用 `_mirrorSliceHistory`，收集 `seenIds`。需要收尾时（本地原本就有 `peerhist_*` 行，或收到 `reset`），中间页不存游标，最后一页之后删掉不在 `seenIds` 里的 `peerhist_*` 行，再存游标。
- 需要收尾的重建里，`latestMirroredLocalAt` 只从 `seenIds` 对应的行里取。
- 空的 reset 存 `cursor = ""`、`total = 0`，不再删游标。
- `_mirrorFullHistory` 只在旧 Hub（响应没有 `cursor`）时使用。

Hub 侧要点：`validated_stable` 改成 `messages.len() < count` 就判定失效；游标失效时按 `limit` 分页返回并带 `reset: true`，不再整段返回。

## 4. 可选的小问题

- **旧 Hub 下保存灵魂可能记到别的 agent 上**：`_takePendingSoulText` 在响应没有 `request_id` 时取任意一个挂起项。改成先按响应里的 `agent_id` 找，找不到再退回现在的做法。
- **游标条数按远端会话 id 汇总**：`peerHistoryCursorTotalsByRemoteSession` 的 key 只有远端会话 id。同一个远端会话同时对应 `psess_` 和旧格式两个 channel 时会互相覆盖。改成取两者里较小的 `total`，宁可多同步一次也不要漏。
- **范围外的改动单独提交**：`3c89c86` 里"内置引擎直接用 app 自带的 SVG 头像"那段 `_resolvePeerAvatar` 改动和缓存无关，拆成单独的提交。
- **格式化单独提交**：`2d3572b` 对 `peer_agent_client_service.dart`、`local_database_service.dart`、`channel_dao.dart`、`message_dao.dart` 整个文件跑了 `dart format`。以后先单独提交一次纯格式化，再提交功能改动。这次已经合在一起就不用拆了，后面的修复不要再整文件格式化。

## 测试

放在 `test/peer/`，沿用 `peer_agent_meta_cache_test.dart` 和 `peer_history_cursor_test.dart` 里的测试辅助函数：

- 推送：投递一帧 `agent_meta_changed`（`kind: soul`），缓存被写入、`metaChanged` 发出一条；同时有一个挂起的 `fetchSoulInfo`，它**没有**被这一帧完成，之后真正的 `agent_soul_resp` 到来时才完成。
- 推送 `commands`：缓存和 `/` 面板的 stream 都更新，挂起的 `fetchCommands` 不被完成。
- `rev`：连续两次投递 `rev` 相同的 `agent_modes_resp`，第二次不写库（`fetched_at` 不变）、不发 `metaChanged`。`rev` 为空时每次都写。
- `scope`：`scope: "session"` 的响应不写缓存。
- `not_switchable`：`setModelResult` 返回 `error == 'not_switchable'`，缓存里 `switchable` 变成 false，`current` 不变。
- 灵魂 `exists: false`：写入空灵魂。
- 聊天输入区（widget 测试，或者把判断抽成纯函数测）：离线加载后投递 `connected` 事件，`_peerControlsOffline` 变成 false，并发出了模式和模型请求。
- 历史游标：按历史游标方案"App 测试"一节新增的几条（分页重建、重建中断、升级路径、尾巴被删、空 reset、超大会话）。

## 验收

- 两台手机连同一台电脑：在 A 上切模式、切模型（惜宝）、改灵魂，B 停在对应页面时几秒内自动更新；B 上正在编辑的灵魂输入框不被覆盖，只出现提示。
- 在引擎 agent 上切模型时提示"这个 Agent 的模型在电脑上配置"，之后入口变成只读。
- 关掉 Hub 打开聊天页，再启动 Hub：不退出页面，模式和模型入口在连上后变成可切换。
- 一个原始 JSON 超过 4 MB 的会话，在新装 App、升级后首次同步、远端回滚后三种情况下都能完整同步，Hub 日志里每次响应都不超过约 1 MB。
- `flutter analyze` 对改动文件无新增告警；`flutter test --exclude-tags=needs-plugins test/peer` 除了已知的 `pouch_roster_test` 两条外全部通过；`cargo test --workspace` 通过。

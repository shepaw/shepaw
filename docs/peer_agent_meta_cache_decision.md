# Peer Agent 元数据本地缓存

状态：待实现
范围：App（`shepaw/lib`）。不依赖 Hub 改动，可以单独上线。Hub 侧的配合方案见 `shepaw-cli/docs/design/2026-10-04-agent-meta-cache.md`，第 7 节说明 App 怎么接上它

## 背景

Peer agent（Hub 上的第三方 Agent）的几类元数据目前只存在内存里，每次进入页面都要实时向 Hub 请求：

| 数据 | 请求 | 现在的缓存 | 使用方 |
| --- | --- | --- | --- |
| 上游模型列表 + 当前模型 | `agent_models_req` | 无，只有 in-flight 去重 `_pendingModels` | `chat_input_area.dart`、`remote_agent_detail_screen.dart` |
| 会话模式列表 + 当前模式 | `agent_modes_req` | 无，只有 `_pendingModes` | 同上 |
| 斜杠命令 | `agent_commands_req` | 内存 `_commandsCache`，进程重启即丢 | `chat_screen.dart` 的 `/` 面板 |
| 灵魂（system prompt）| `agent_soul_req` | 无 | `remote_agent_detail_screen.dart`、`agent_soul_edit_screen.dart` |

带来的问题：

1. 进入聊天页时，输入区的模式 chip、模型 chip 要等网络回来才出现。`chat_input_area.dart` 里先 `await _loadSessionModes` 再 `await _loadPeerModels`，**串行**执行，每个超时 15 秒。
2. 离线时模型入口直接隐藏，模式退回引擎内置目录 `catalogModesList`，和用户上次看到的不一致。
3. App 冷启动后，`/` 面板在 `agent_list_resp` 触发的预取完成前是空的。离线时整个会话期间都是空的。
4. 详情页的模型和灵魂区域每次进入都显示 loading。
5. 超时和"对端确实不支持"都返回空列表，调用方分不清。

目标体验参考微信：**先展示本地上次的结果，连接可用时后台刷新，变了再更新界面。网络失败不清空已有内容。**

## 目标与非目标

目标：

- 上述四类元数据落库，进页面时先从库里读出来直接渲染（stale-while-revalidate）。
- 在线时照常刷新，刷新失败或超时不覆盖缓存。
- 模式和模型并行请求。
- Agent 被删除、App 数据重置时缓存一起清掉。

非目标（另立方案）：

- 会话历史按游标增量拉取（需要 Hub 协议改动）。
- 启动路径瘦身（`AppBootstrap.initialize` 中把非关键步骤移到首帧后）。

Hub 主动推送元数据变更不在第 1–6 节的范围里，接入方式单独写在第 7 节。

## 设计

### 1. 存储：新表 `peer_agent_meta_cache`

`agents.metadata` 不能用来存这些数据：`_onAgentList`（`peer_agent_client_service.dart`）每次收到名单都会重写 agent 行，存进去会被覆盖。所以单独建表。

```sql
CREATE TABLE IF NOT EXISTS peer_agent_meta_cache (
  agent_id   TEXT NOT NULL,   -- 本地 agent 行 id；peer agent 的本地 id 就是 remoteAgentId（见 peer_agent_ids.dart）
  kind       TEXT NOT NULL,   -- 'models' | 'modes' | 'commands' | 'soul'
  scope      TEXT NOT NULL DEFAULT '',  -- '' 表示 agent 级；否则是远端 session id（裸 id，与请求里的 session_id 一致）
  payload    TEXT NOT NULL,   -- JSON
  fetched_at INTEGER NOT NULL, -- 毫秒时间戳
  PRIMARY KEY (agent_id, kind, scope)
);
```

- 数据库版本 `34 → 35`（`local_database_service.dart` 中 `openDatabase(version: 34)`）。在 `_onCreate` 的建表段和 `_onUpgrade` 新增的 `if (oldVersion < 35)` 分支各建一次，写法参照 v28 的 `history_compaction_cache`，失败时同样只打日志。
- payload 格式：
  - `models`：`{"models":[{"value","display_name","description"}], "current": "<value>|null", "switchable": true|false}`
  - `modes`：`{"modes":[{"value","display_name","description"}], "current": "<value>|null"}`
  - `commands`：`{"commands":[SlashCommandInfo.toJson()...]}`（`SlashCommandInfo` 已有 `toJson`/`fromJson`）
  - `soul`：`{"soul":"...", "editable": true|false}`
- `PeerAgentModel`、`PeerAgentMode` 目前只有 `fromJson`，需要补 `toJson`，字段名与线上协议一致（snake_case）。
- `PeerModelsList` 加 `switchable` 字段（默认 true，兼容不发这个字段的旧 Hub），`_onModelsResp` 从 `data['switchable']` 读取。

`scope` 的用法：现在的 Hub 把模式和模型都存成 agent 级的（`<agent_id>/mode.txt`、`model.txt`），请求里的 `session_id` 会被忽略。所以**这一期四类数据一律写 `scope=''`**，读也只读 `scope=''`。

`scope` 列先保留不用。以后 Hub 在响应里声明 `"scope": "session"` 时再启用按会话存储，届时规则是：整份结果写到 `scope=sessionId`，列表部分同时 upsert 到 `scope=''`；读取时先查会话、再回退到 agent 级；每个 `(agent_id, kind)` 只保留最新的 50 条会话行。这一期不用实现 prune。

### 2. DAO：`services/database/peer_agent_meta_cache_dao.dart`

参照 `history_compaction_cache_dao.dart`，写成 `LocalDatabaseService` 的 extension：

```dart
extension PeerAgentMetaCacheDao on LocalDatabaseService {
  Future<PeerAgentMetaCacheEntry?> getPeerAgentMeta(String agentId, String kind, {String scope = ''});
  Future<List<PeerAgentMetaCacheEntry>> getAllPeerAgentMeta(String kind); // 启动时批量预热 commands 用
  Future<void> upsertPeerAgentMeta(PeerAgentMetaCacheEntry entry);
  Future<void> deletePeerAgentMeta(String agentId);
}
```

`PeerAgentMetaCacheEntry` 是一个简单的不可变类（`agentId/kind/scope/payload(Map)/fetchedAt`），带 `toMap`/`fromMap`。

### 3. 写入：只在收到响应时写，超时与失败不写

缓存写在各 `_onXxxResp` 处理函数里，不放在 `fetchXxx` 的返回路径上。原因：fetch 超时和对端不支持都返回空列表，在返回路径上分不清；而只要响应到达，就说明对端确实回答了，**即使列表为空也是有效结果**（表示不支持，应缓存下来，离线时据此隐藏入口）。

| 处理函数 | 写入 |
| --- | --- |
| `_onModelsResp` | `models`（含 `switchable`，见第 5 节） |
| `_onModesResp` | `modes` |
| `_applyCommandsResp` | `commands`（它同时被 `_onCommandsResp` 和其他路径调用，写在这里能覆盖全部来源） |
| `_onSoulResp` | 仅当结果 `isOk` 时写 `soul`，宿主明确拒绝（`error != null`）时不写 |
| `_onModelsSetResp` / `_onModesSetResp` | `ok == true` 时，把缓存里的 `current` 更新为新值 |
| `_onSoulSetResp`（保存成功时） | 用新文本更新 `soul`。Hub 的 `write_text` 会回传正文 `soul`，优先用它；没有时用发起 set 时记下的文本 |

写库要 `unawaited`，并捕获异常只打日志，不能影响 completer 完成。

### 4. 读取：服务层 API

在 `PeerAgentClientService` 上加只读缓存接口，UI 不直接碰 DAO：

```dart
Future<PeerModelsList?> cachedModels(String localAgentId);
Future<PeerModesList?> cachedModes(String localAgentId);
Future<PeerSoulInfo?> cachedSoul(String localAgentId);
```

返回 `null` 表示从没缓存过；返回空列表表示对端明确不支持。两者要区分对待。

斜杠命令单独处理，因为 `getSlashCommands` 是同步接口：

- `PeerAgentClientService.start()` 里 `unawaited` 调一次 `getAllPeerAgentMeta('commands')`，把结果灌进 `_commandsCache` 并推给已有的 `_slashCommandsStreams`。不要 await，避免拖慢启动。
- `ensureCommandsForLocalAgent` 目前在缓存非空时直接 return（`peer_agent_client_service.dart` 约 3607 行）。预热后缓存永远非空，会导致**永不刷新**。改为：维护一个 `_commandsFreshThisConnection: Set<String>`，在 `_applyCommandsResp` 时加入，在对应 peer 断线时清掉（监听 `PeerConnectionManager.instance.events` 的 disconnected）。判断条件改为"本次连接内已刷新过才跳过"。
- `agent_list_resp` 之后已有的预取逻辑（约 4563 行）保持不变。它会在每次连上时刷新一遍，正好覆盖预热的旧数据。

### 5. 页面改造

**`widgets/chat/chat_input_area.dart`（聊天输入区）**

把 peer 分支（约 364 行）改为两段：

1. 先读缓存并立即 `setState`：
   - 模式：缓存 → 引擎目录 `catalogModesList` 兜底。
   - 模型：有缓存就显示。
2. 已连接时，用 `Future.wait` **并行**请求模式和模型。结果回来、token 仍匹配（`_controlsToken`）时再 `setState`。规则沿用现有逻辑：在线返回空模式列表时退回目录，模型返回空列表时隐藏入口。网络请求返回空、且看起来是超时（无法区分时一律按超时处理）的情况下，**保留缓存显示**，不要清空。

   实现提示：为了区分超时，可以给 `fetchModels`/`fetchModes` 内部加一个 `({PeerModelsList list, bool completed})` 形式的私有变体，做法参照现有 `_fetchHistory`。公开签名保持不变，避免影响其他调用方。

离线时的模型入口（已定）：**显示缓存里的当前模型，但置为不可切换**，点击时提示"设备离线，暂不能切换模型"。从没缓存过、或缓存里是空列表时，仍然隐藏入口。`_loadPeerModels` 上方的注释（离线不显示入口）要同步改掉。提示文案在 `app_zh.arb` 和 `app_en.arb` 里各加一条。

离线时的模式入口同样处理：显示缓存值（没有缓存时显示引擎目录），但不能切换，点击时提示同一条文案。

`switchable == false` 时（现在的 Hub 对所有引擎 agent 都这样返回，只有惜宝可切），无论在线离线，模型入口都只显示当前模型、不能切换，点击时提示"这个 Agent 的模型在电脑上配置"。现在 App 没读这个字段，会让用户"切换"一个实际不生效的模型。提示文案同样在两份 arb 里各加一条。

**`screens/remote_agent_detail_screen.dart`（Agent 详情页）**

- 模型区（约 320 行）：有缓存时先显示缓存，`_peerModelsLoading` 只控制一个小的刷新指示，不再整块转圈。刷新失败但有缓存时，不显示 `agentDetail_modelSwitchUnsupported` 错误。
- 灵魂区（约 273 行）：先用 `cachedSoul` 填充 `_displaySoul` 和 `_systemPromptController`。离线时 `_peerSoulEditable` 强制为 false。刷新成功后覆盖；失败且有缓存时不设 `_soulFetchFailed`。注意：用户已经开始编辑时，后台刷新回来**不能覆盖输入框**，需要判断控制器文本是否仍等于缓存值。
- 模式区（约 402 行）同模型区处理。

**`screens/agent_soul_edit_screen.dart`（灵魂编辑页）**

约 124 行处同样先读缓存再刷新，同样不能覆盖用户正在编辑的内容。

### 6. 失效与清理

- `remote_agent_dao.dart` 的 `deleteRemoteAgent`：在同一事务里一起删除 `peer_agent_meta_cache` 中该 `agent_id` 的行。`_reconcileDeletions` 和名单比对删除 agent 都走这个方法，能一起覆盖。
- 同时清掉内存里的 `_commandsCache[agentId]`，并向对应 stream 推一个空列表。
- `LocalDatabaseService.clearAllData()` 增加 `await db.delete('peer_agent_meta_cache');`。
- `clearAllDatabases()` 删除整个库文件，无需改动。
- 不设硬过期时间：显示永远可以用旧数据，新鲜度靠"在线时进入页面就刷新"和"每次连上时预取命令"保证。

### 7. 接入 Hub 配合改动（Hub 方案上线后做）

Hub 方案的改动都是只加不改，App 下面这些处理在旧 Hub 上自动不生效，不用判断版本。

- **`rev` 字段**：存进缓存行（payload 里加 `rev`）。刷新回来的 `rev` 和缓存相同时，不写库、不 `setState`，避免无意义的重绘。
- **`scope` 字段**：这一期只认 `"agent"` 或缺省，按第 1 节只存 agent 级。Hub 目前不会返回 `"session"`，等 Hub 真的支持按会话的模式时，再实现第 1 节预留的按会话存储。
- **灵魂 `exists: false`**：当作合法的空灵魂写入缓存。`ok: false` 时按第 3 节不写。
- **设置失败的新错误码**：`agent_models_set_resp` 回 `not_switchable`、`agent_modes_set_resp` 回 `unknown_mode` 时，不改缓存，界面回滚到原值，并给出提示。`not_switchable` 还要把缓存里的 `switchable` 改成 false。
- **推送帧 `agent_meta_changed`**：在 `_onControl` 里新增一个 case。按 `kind`（`models` / `modes` / `soul` / `commands`）把 `data` 交给和对应 `*_resp` 相同的解析逻辑，写入缓存，**但不要去完成任何挂起的请求**（推送帧不是哪个请求的回复）。`commands` 直接走 `_applyCommandsResp`。
- **界面实时更新**：给 `PeerAgentClientService` 加一个 `Stream<({String agentId, String kind})> metaChanged`。缓存写入（不管来自响应还是推送）且 `rev` 变化时发一条。`chat_input_area.dart`、`remote_agent_detail_screen.dart`、`agent_soul_edit_screen.dart` 订阅后，对当前 agent 重新读缓存。灵魂编辑页仍然遵守"不覆盖用户正在编辑的内容"：内容有冲突时只提示"已在其他设备修改"，不替换输入框。

对应测试：相同 `rev` 不触发写库；`agent_meta_changed` 写缓存、发 `metaChanged`、不完成挂起的 `fetchSoulInfo`；`not_switchable` 回滚并更新 `switchable`。

## 实现步骤

1. 数据库 v35 建表，加 DAO 和 `PeerAgentMetaCacheEntry`，给 `PeerAgentModel`/`PeerAgentMode` 补 `toJson`。
2. 在 `PeerAgentClientService` 的响应处理里写缓存，读 `switchable`，加 `cachedModels/cachedModes/cachedSoul`。
3. 斜杠命令：启动预热，修改 `ensureCommandsForLocalAgent` 的跳过条件，加断线清标记。
4. 改 `chat_input_area.dart`：先缓存、后并行刷新。
5. 改 `remote_agent_detail_screen.dart` 和 `agent_soul_edit_screen.dart`。
6. 删除与重置时的清理。
7. 测试（见下）、`flutter analyze`、`flutter test --exclude-tags=needs-plugins`。
8. Hub 方案合并后，按第 7 节接入。

每一步都可以独立提交，1–3 步做完后行为还不会变化，便于评审。

## 测试

单元测试放在 `test/peer/`（`peer_incremental_sync_test.dart` 里有可参考的数据库测试写法）：

- DAO：upsert / get 往返；`deleteRemoteAgent` 一起删除缓存行。
- 写入规则：模拟 `agent_models_resp` 到达后缓存被写入；fetch 超时（不投递响应）时缓存保持原样；空列表响应会被写成空列表；`agent_soul_resp` 带 error 时不写；`switchable` 缺省时按 true 处理。
- `setModel` 成功后缓存的 `current` 被更新，失败时不变。
- 斜杠命令：预热后 `getSlashCommands` 立即有值；预热过的 agent 调用 `ensureCommandsForLocalAgent` 仍会发出请求；本次连接内刷新过之后不再重复请求；断线后再次进入会重新请求。

## 验收标准

- 在线：进入 peer agent 聊天页，模式 chip 和模型 chip 在首帧就显示上次的值，网络返回后如果有变化再更新，期间不闪烁、不消失。
- 离线（Hub 关闭后重启 App）：聊天页能看到上次的模式和模型（都不可切换，点击时提示设备离线），`/` 面板有上次的命令，详情页显示上次的灵魂（只读）。
- 一次请求超时不会让已经显示的内容消失。
- 删除 agent 或重置 App 数据后，再添加同 id 的 agent，不会显示旧的缓存。
- `flutter analyze` 无新增告警，测试通过。

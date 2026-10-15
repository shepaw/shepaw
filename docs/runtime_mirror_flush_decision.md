# runtime 镜像与储物袋落盘的写入频率

状态：待实现
范围：App（`shepaw/lib`）。只改写入时机与写入体积，不改路径、不改格式、不改权威分层。主机侧无需改动。

## 背景

一条消息落库后会同步触发一整条「镜像 → 储物袋 → 同步日志」的写链，且**每一层都是全量重写**：

```
message_dao.dart:103  RuntimeMirrorService.onMessageCreated(channelId)   ← 每条消息
  └ runtime_mirror_service.dart:42  _resolveAndScheduleSession
        getChannelById + getRemoteAgentById + resolvePeerAttachmentPlacement   （3 次 await）
  └ :100  Timer(debounce 400ms)
  └ :175  _mirrorSession
        ensureRuntimeScaffold  :184   4 × _writeTextIfAbsent（各一次 store.meta 探测）
        getChannelMessages(limit 200) :189   逐行 jsonDecode :202
        JsonEncoder.withIndent('  ') :230   缩进序列化（体积膨胀 2–3 倍）
        _writeText(session.json) :254    sha256 全文 + writeBegin + chunk + commit
        _touchManifestChannel :260      读回 manifest + 再写一份
  └ local_store commit
        sync_journal.appendCommit :302  _saveQueue + _saveState + recent（各自 jsonEncode → .tmp → rename）
        onAppended → sync_engine.poke :130/:186  → syncNow（无防抖）
             master 是本机时 dequeueThrough 又把 queue/state 重写一遍
             _emitStatus 至少两次，每次读一遍 pending 并广播（触发 UI 重建）
```

流式回合每 2 秒 flush 一次全文（`streaming_flush_helper.dart:87`），所以**一个 60 秒的回合会把上面整条链跑约 30 遍**：30 ×（200 行读 + 200 次 jsonDecode + 2 次缩进序列化 + 2 次 store 写 + 每次写 3–5 个 JSON 文件重写 + 2 次 fsync + 2 次状态广播）。会话越长单次越贵，是「聊久了越来越卡」的主要来源。

## 目标与非目标

目标：

- 把「一条消息 → 一次全量镜像」降成「一个回合 → 一次全量镜像」，静止时仍能收敛到最新。
- 去掉每条消息镜像前那 3 次数据库读。
- 缩小写盘体积（去掉缩进）。
- 给 `sync_engine` 的即时同步加防抖，避免连续写各触发一轮。

非目标（本次不做）：

- 把 session.json 改成增量追加（要改格式和滚动逻辑，收益不如降频明显）。
- `sync_journal` 的 queue/state/recent 合并成单文件（改动面大，降频后调用次数已大幅下降）。
- 附件写入的 isolate 化（另立方案）。
- 搜索防抖（另立方案）。

## 设计

### 1. 镜像：空闲 debounce 2s + 最长落后 10s 兜底

`RuntimeMirrorService.debounce` 保持**空闲 debounce** 语义（每次写入重置计时器），只是把窗口从 400ms 放宽到 2s。静止时 2 秒内收敛。

流式回合里消息持续到达，空闲窗口会被一直重置、直到回合结束才写，所以再加一个 `maxStaleness`（默认 10s）：待写条目存在超过 10s 就在下一次写入时立即落盘，不再继续攒。60 秒的回合从约 30 次降到约 6 次。

两个额外出口：

- `flushPendingSessions()`：立即回放所有待写条目。留给调用方在确定的终态（回合结束、离开会话）时用。
- `AppLifecycleService.didChangeAppLifecycleState` 在 paused / hidden / detached 时调一次：切后台后计时器不会再有机会触发，必须显式收敛。

不改动 `ChatController`：回合终态那次强制 flush 是「更快」，不是「必须」——有 `maxStaleness` + 切后台兜底后镜像最多落后 10 秒，且 App 侧不读它（见「取舍」）。

### 2. 序列化：去掉缩进

`runtime_mirror_service.dart:230/252` 的 `JsonEncoder.withIndent('  ')` 改成 `jsonEncode`。session.json 的定位是「跨设备只读上下文 / `pouch://` 分享」（`docs/CLIENT_PROFILES.md:19`），不是人天天打开手改的文件；storage 浏览页有自己的渲染。体积和编解码耗时都降到约 1/2–1/3。

`ensureRuntimeScaffold` 里 scaffold 内容本身的缩进保留（它只在首次创建时写一次，且给人看）。

### 3. 解析：缓存 channel → (ownerId, deviceId, messagesChannelId)

`_resolveAndScheduleSession`（`:42-85`）现在**每条消息**都跑 `getChannelById` + `getRemoteAgentById` + 可能的 `resolvePeerAttachmentPlacement`。一次会话里这个路由结果不会变，加一个 `Map<String, _MirrorRoute>` 缓存：

- key 是 `channelId`。
- 命中就直接 `scheduleSessionMirror`，跳过 3 次 await。
- 失效点：`deleteChannel`、App 数据重置（`app_data_reset_service.dart` 已有清理钩子，加一行 `invalidateMirrorRoute()`）。
- peer 隧道的 `resolvePeerAttachmentPlacement` 结果同样缓存进这条路由记录。

`ensureRuntimeScaffold`（`:121`）的 4 次 `store.meta` 探测加一个进程内 `Set<String>`「本会话已建过 scaffold」，避免每次镜像都探 4 遍。

### 4. store 落盘：`sync_engine.poke` 防抖

`sync_engine.dart:130` 的 `SyncJournal.onAppended = poke` 改为 `poke()` 内部走一个 500ms 的计时器（对齐 `conversation_list_controller` 的静默刷新防抖写法）。连续写合并成一轮。

- `syncNow()` 本身已有单飞（`_syncFlight`），加防抖不会破坏「立即同步」语义，只是把「每次写都同步」变成「写完 500ms 同步一次」。
- 心跳定时器、peer 上线触发的 `syncNow` 不走防抖，保持立即。
- master 是本机（单设备，最常见场景）时 `syncNow` 只是出队，防抖后这部分开销直接消失。

## 取舍

**镜像时效**。`docs/CLIENT_PROFILES.md:16-19` 已经写死：镜像是**非权威**的单向覆盖写，用途是「人可读浏览、`pouch://` 分享、跨设备只读上下文」，App 聊天与搜索只信 SQLite。所以：

- 落后最多 10 秒（静止时 2 秒）不影响任何 App 内读取。
- 跨设备只读上下文的读者（另一台设备上的 Agent 读 `pouch://runtime/.../sessions/session.json`）最坏情况读到「上一回合结束时的状态」，这本来就是当前语义下的合理边界——现在的实现也不保证 Agent 读到的是正在流式的半截内容。
- 如果将来出现「回合中途必须读到最新镜像」的读取方，再在 `_flushPendingSessions` 上加一个按需 flush 入口，不用改本方案的结构。

**`poke` 防抖 500ms**。跨设备同步的延迟从「写完立刻」变成「写完 500ms」。同步本来就是异步尽力而为（master 离线时会整轮跳过），500ms 不可感知。

## 实现步骤

1. `runtime_mirror_service.dart`：`debounce` → 2s；新增 `maxStaleness` 兜底与 `flushPendingSessions()`；去掉 `withIndent`；加路由缓存 + scaffold 已建集合 + `invalidateMirrorRoute()`。
2. `app_lifecycle_service.dart`：切后台时 `flushPendingSessions()`。
3. `sync_engine.dart`：`poke` 加 500ms 防抖。
4. 单元测试 + `flutter analyze` + `flutter test --exclude-tags=needs-plugins`。

每一步可独立提交。第 1、3 步单独看都是行为等价（只是频率/体积变化），便于评审。

## 测试

`test/storage/runtime_mirror_test.dart` 已有可参考的写法，补充：

- 连续 10 次 `onMessageCreated` 只产生 1 次镜像写（用假的 store 计数 `writeBegin`）。
- `flushPendingSessions()` 立即落盘，且之后计时器已取消（不再重复写）。
- 序列结果不含缩进（断言 `body` 里没有 `\n  "`）。
- 路由缓存：第二次 `onMessageCreated` 不再调用 `getChannelById`（用 spy 或计数）。
- `invalidateMirrorRoute()` 后重新解析。
- `sync_engine`：连续两次 `poke` 在 500ms 内只产生 1 次 `syncNow`（注入假 transport 计数）。

## 验收标准

- 一个 60 秒的流式回合，session.json 的 store 写次数从约 30 次降到约 6 次。
- 回合结束后 2 秒内（空闲 debounce），storage 浏览页打开 `sessions/session.json` 能看到本回合完整内容。
- App 切后台后立即回前台，镜像是最新的。
- 跨设备场景（两台设备配对）下，一侧发消息后另一侧在 1 秒内仍能看到同步结果。
- `flutter analyze` 无新增告警，测试通过。

# 决策记录：会话列表单会话菜单新增「复制到」

## 需求

会话列表（聊天页右侧抽屉 / 桌面固定面板）中，长按单条会话弹出的操作菜单里
新增「复制到」：把该会话复制一份到另一个 agent 下，成为目标 agent 的新会话。

## 现状（结论来自代码）

- 术语：本仓库的「会话」= 一条 `Channel` 行（`type: 'dm'` / `'group'`）。
  长按菜单在 `lib/widgets/chat/session_row_menu.dart:19`（`showSessionRowMenu`），
  现有项：查看会话 / 查看 Trace / 分叉 / 重置会话 / 复制标题+ID / 复制 Channel ID。
- 分叉 `ChatService.forkSession`（`lib/services/chat_service.dart:6375`）已经是
  「复制会话」的 95%：`_forkDmChannel` 建新 channel（id 规则
  `dm_<sortedIds>_<ts>`），`_copyChannelData`（`:6431`）批量复制 `messages`
  （重写 message id / reply_to_id）与 `tool_executions`（独立库，重写 tool_call_id）。
- 控制器侧 `forkSession`（`lib/controllers/chat_controller_sessions.dart:231`）：
  发 loading overlay → 调 service → `touchChannelUpdatedAt` → 清空会话 →
  `NavigateToSessionEvent`。
- 跨 agent 导航已支持：`_handleNavigateToSession`
  （`lib/screens/chat_screen.dart:5141`）里 `crossAgent` 判定后回退整页替换。
- 抽屉内操作必须先 `_closeDrawerAndWait()` 再执行（共享动画控制器会被 dispose，
  抽屉会冻结），见 `_forkDrawerSession`（`:5305`）。

## 决策

### D1. 只对 DM 会话提供，群会话不提供

理由：群会话的归属是「群家族」，不是单个 agent；复制到某 agent 语义不成立。
`GroupSessionListPanel` 的菜单参数保持不动（`onCopyToAgent` 不传 → 该项不显示）。

### D2. 复制语义 = 在目标 agent 下新建一条 DM 会话 + 搬消息

- 新 channel：`type='dm'`，`members=[userId, targetAgentId]`（`ChannelMember`
  的 type 要把 agent 侧标成 `'agent'`，否则 `Channel.agentIds` 为空、
  会话列表/发送路径拿不到 agent）。
- id 规则沿用分叉：`dm_<sorted(userId, targetAgentId)>_<ts>`。
- 名称沿用原会话名（列表标题本来就取首条消息，名字只是兜底）。
- **清除 `sourceGroupChannelId` / `sourceSheChannelId`**：与分叉一致，
  避免副本继承「群绑定 / She 中转」的只读绑定语义。
- 原会话不动（复制不是移动）。

### D3. 复制体量 = 消息 + 工具执行历史

直接复用 `ChatService._copyChannelData`，不新增复制逻辑。新增服务方法
`copySessionToAgent(...)` 放在 `forkSession` 旁边，内部建 channel 后调
`_copyChannelData`。

### D4. 目标选择：单选 agent 面板（新增 `CopyToAgentPicker`）

- 数据源 `LocalDatabaseService().getAllRemoteAgents()`，过滤掉当前 agent。
- 桌面走 `LayoutUtils.showRightDrawer`，移动端 `Navigator.push` + Scaffold
  （与 `_showAddGroupMemberPicker` / `AddGroupMemberPicker` 同款）。
- 单选 + 搜索过滤，样式照抄 `AddGroupMemberPicker`（去掉多选与默认选中 She）。

### D5. 完成后跳转新会话

沿用分叉的收尾：`touchChannelUpdatedAt` → `pruneEmptySessionBeforeSwitch` →
`NavigateToSessionEvent(channelId, agentId: target.id, agentName, agentAvatar)`。
跨 agent 时 `_handleNavigateToSession` 自然走整页替换。

### D6. i18n

`app_zh.arb`（模板）+ `app_en.arb` 新增：`chat_copySessionTo`（复制到）、
`chat_copySessionToTitle`（选择目标 Agent / 复制到 Agent）、
`chat_copyingSession`（正在复制会话…）、`chat_copySessionFailed`（复制会话失败：{error}）。
失败 key 需在 `_resolveSnackBarMessage`（`chat_screen.dart:5290`）注册。

## 落地顺序（每轮单独 commit）

1. l10n：两个 arb + `flutter gen-l10n`。
2. service：`ChatService.copySessionToAgent`。
3. controller：`copySessionToAgent`（照 `forkSession`）。
4. UI：菜单项 + `onCopyToAgent` 透传（`session_row_menu` → `session_list_panel`
   → `chat_screen`）+ `CopyToAgentPicker`。
5. 冒烟：`flutter analyze` + 相关 widget test。

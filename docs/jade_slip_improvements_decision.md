# 玉简（Jade Slip）四项优化：决策记录

> 日期：2026-09-22
> 来源：玉简待办「玉简优化」（4 项清单，指派给 shepaw 执行）

## 1. 背景与约束

玉简是储物袋 `notes` 分区的待办（`store://notes/<device>/slips/<id>.json`），
用户写、Agent 用 `shepaw notes …` 执行。四条清单项都是同一个页面的改动，
但涉及三种不同性质的变更：

| 项 | 性质 | 是否动数据结构 |
|---|---|---|
| 标题支持多行展示 | 纯展示 | 否 |
| Agent 可在玉简上添加评论 | 新能力 | 是（新增 `comments`） |
| 指派 agent 展示头像 + 设备标签 + 搜索过滤 | 交互重构 | 否（复用 `PeerSourceBadge`） |
| 清单可改 + 删除图标换更多操作 | 交互 + 一个写接口 | 否（复用 `items`） |

共同约束：

1. **落盘格式向后兼容**。`JadeSlip.fromJson` 必须容忍旧文件（无 `comments`），
   新字段一律「空则省略」写回（`toJson` 里 `if (list.isNotEmpty)`），与现有
   `attachments` / `tags` 一致。
2. **Agent 侧必须能用 CLI 完成同样动作**，否则「关联到 agent 处理过程」这条不成立。
   评论要同时有 `notes comment`，清单改字要同时能 `notes item --item --text`。
3. **身份靠执行上下文**，不靠调用方自报。评论作者取 `ChatAgentScope.agentId`
   （Zone 内注入），用户在 App 内写的评论取 `LocalUserIdentity.id`（`'user'`），
   与 `notes delete` 已有的权限判定同一套口径。

## 2. 逐项决策

### 2.1 标题多行

- 列表行（`_SlipRow`）标题 `maxLines: 1 → 2`；元信息行保持 1 行。
- 编辑页标题输入框改为可换行（`maxLines: null`）。玉简标题是「一句话待办」，
  不做成多行大文本框，只是允许长标题折行，输入仍回车换行、不拦截。

不做：列表按内容动态行数（会破坏列表对齐与滚动性能）。

### 2.2 评论

新增 `JadeSlipComment { id, authorId, authorName, text, createdAt }`，
存在 slip 的 `comments` 数组里，**不单独开文件/目录**——评论体量小，
跟着 slip 一起走才能靠 `updatedAt` 做跨设备合并（单开文件会出现
「slip 与评论各合并一次」的撕裂）。

- 服务：`addComment` / `removeComment`，都走 `update()` 复用已有的
  `updatedAt` + 通知流。
- CLI：`notes comment`（`--text` 新增，无 `--text` 列，`--comment + --delete` 删）。
- UI：编辑页「备注」下方加「评论」区，展示作者名 + 时间 + 正文，
  底部一行输入框（作者 = 本机用户）。App 内不提供删除他人评论的入口，
  只删自己写的（`authorId == LocalUserIdentity.id`）——避免误删 agent 的过程记录。

### 2.3 指派 Agent 的选择器

现状三处各写一遍弹层：`_AssigneePill`（PopupMenuButton）、`_pickRunAgent`
（showMenu）、`dispatchJadeSlip`（SimpleDialog），且都只显示名字。
统一抽一个 `showJadeSlipAgentPicker`：

- 头像：`AgentListAvatar`（与会话列表同款，emoji/图片/首字母回落）。
- 设备标签：peer agent 用现成的 `PeerSourceBadge.fromAgent`；
  非 peer（本机/内置）显示「本机」小标。
- 搜索：弹层顶部输入框过滤 名称 + 设备名。PopupMenuButton 装不下输入框，
  所以统一改成 `showDialog` + 内部 `ListView`（同时解决三处不一致）。
- 仍保留 She 置顶项与「不指派」项。

### 2.4 清单项可改 + 更多操作

- 每项右侧 `Icons.close` → `Icons.more_vert` 的 `PopupMenuButton`：编辑 / 删除。
- 编辑：行内换成 `TextField`（自动聚焦，失焦或回车即保存，Esc/清空逻辑不做），
  服务新增 `updateItemText`。
- 保留 `Dismissible` 侧滑删除（肌肉记忆不打破），但 Dismissible 与
  PopupMenuButton 并存时点击目标要分开：菜单在行尾，侧滑仍生效。

## 3. 落地顺序

按「无数据改动 → 有数据改动 → 交互重构」排，每项单独一个 commit：

1. 标题多行
2. 清单可改 + 更多操作图标
3. 评论（model → service → CLI → UI）
4. 指派选择器（头像 / 设备标签 / 搜索）

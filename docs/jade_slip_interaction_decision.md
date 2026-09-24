# 玉简交互优化（第二轮三项）：决策记录

> 日期：2026-09-23
> 来源：玉简待办「玉简交互优化」（3 项清单，指派给 shepaw 执行）

## 1. 背景

上一轮（`docs/jade_slip_improvements_decision.md`）把玉简做成了「用户写、Agent
执行」的完整闭环：`shepaw notes` 命名空间 10 个子命令齐备，评论、指派、清单改字
都已落地。本轮三项是闭环之后暴露的缺口——**读得懂**（外接 agent 知不知道有玉简）、
**写得下**（清单能不能输入多行）、**看得见**（编辑页顶部认不认这条玉简）。

| 项 | 性质 | 是否动数据结构 |
|---|---|---|
| 外接 agent 明白玉简 | 提示词注入 | 否 |
| 清单项支持多行填写 | 交互 | 否 |
| 编辑页标题栏跟随标题 | 纯展示 | 否 |

## 2. 逐项决策

### 2.1 外接 agent 要知道玉简（item `a685b100`）

**结论：现在只有一半明白。** 实测（`SHEPAW_STORE_AGENT_ID=<本机 shepaw>` 跑 shim）：

- `shepaw help` → 命名空间清单里**有** `notes`，描述完整；
  `shepaw notes` → 10 个子命令全列出来。**执行面没问题。**
- 但没有任何一处**主动告诉** agent「有玉简这回事」：
  - `ScopeCard.toStableMarkdown()`（`lib/storage/scope_card.dart:701`）是每轮唯一
    说明书，外接 ACP / Hub 引擎都会收到，里面只有 store / memory / soul，**没有
    notes**。
  - `HubCliExecute.groupContextHint()`（`hub_cli_execute.dart:106`）与
    `group_context_builder.dart:204` 的 `ctx['cli']` 只给 `namespace: 'store'`
    一个例子，没说「还有别的命名空间，跑 `shepaw help` 看」。
  - `SheService._nonSheMetaCliBlock()`（`she_service.dart:1616`）逐项列 Web /
    Store / Vision / OS / Meta，**没有玉简**。
  - 群成员被 `kGroupMemberCliAllowlist = {'store', 'help'}`
    （`cli_execution_gate.dart:200`）收窄，即使知道了也执行不了。
- 唯一让外接 agent 明白的通路是用户点玉简「交给 Agent」→
  `JadeSlip.toAgentPrompt()` 预填的草稿。用户随口说「记到玉简」时它不会想到。

**修法：把 notes 写进每轮说明书，而不是等 agent 自己探索。**

1. **Scope Card 加 notes 行**（主改动）。`ScopeCardCapabilities` 加 `notes`
   （默认 true；`groupMember` 也保留 true——勾选清单是协作动作，不是写个人认知袋）。
   渲染按 `cliSurface` 三态，与既有的 `_storeReadLine` / `_storeWriteLine` 同款：
   - `shepawTool` → `` `shepaw notes list` / `notes get --id <id>` /
     `notes item --id <id> --item <itemId> --done true` ``
   - `hubStoreCli`（Hub 引擎走本机 shim）→ 同上（多一句「本机 device」提示）
   - `hubExecuteCli`（远端 ACP）→ `hub.cli.execute` 带 `namespace:"notes"` 与
     `session_id`
2. **`kGroupMemberCliAllowlist` 加 `'notes'`**。否则 Scope Card 说了、执行闸门会拒，
   两份"允许"必须一致（这正是 `extraAllowlistFor` 存在的理由）。
   `notes delete` 本身已有「仅用户 / She」的权限判定，不必额外收窄。
3. **`groupContextHint()` / `ctx['cli']` 的 note 末尾补一句**：可用命名空间不止
   store，`shepaw help` 拿完整清单。一行字，不动结构。
4. **`_nonSheMetaCliBlock` 加「玉简」小节**（`allowed('notes')` 时），与 Web / OS /
   Meta 并列；`buildMetaCognitionBlock` 的 "Discover on demand" 加一行
   `shepaw notes --help`。

**不做 / 另案**：
- 不在 Scope Card 里贴完整 10 个子命令用法（卡片要短，细节留给 `--help`）。
- shim 的 `shepaw --help` 静态文本（`agent-bridge` 仓库
  `implementations/acp-proxy-ts/src/shepaw-cli.ts:144`）只列 store/group/context/
  chat，**不含 notes**；`shepaw help`（无横线）转发给 App 才完整。外接 agent 先试
  `--help` 是本能，这里是个真缺口，但改动在另一个仓库，另行处理。

### 2.2 清单项多行填写（item `b3e03122`）

现状两处输入都是单行：`_AddItemRow`（`jade_slip_editor_screen.dart:1207`）与
`_ChecklistRow` 编辑态 TextField（`:1113`）——默认 `maxLines: 1`，长文本只能横向滚，
看不到全貌。展示态 `Text(item.text)` 本来就会折行，不用动。

**冲突点**：最近两个 commit（"回车后保持焦点以便连续输入"、"失焦/回车自动保存"）
把 **回车 = 提交** 固化成了肌肉记忆；改成多行后回车默认变换行，会直接打破它。

**决策：两者都要，靠修饰键分道。**

- 输入框：`minLines: 1, maxLines: 6, keyboardType: TextInputType.multiline,
  textInputAction: TextInputAction.newline`，随内容增高（6 行封顶后内部滚动，
  避免长文本把页面顶穿）。
- 回车：**无修饰键仍提交**（`_AddItemRow` 添加并保焦；`_ChecklistRow` 保存并跳到
  添加项），**Shift+Enter 换行**。物理键盘侧用 `Focus(onKeyEvent:)` 在父节点拦
  Enter —— key 事件先走 focus 链再走 `Shortcuts`，父节点返回 `handled` 就能抢在
  `EditableText` 的 newline action 之前。
- `_AddItemRow` 右侧**补一个提交按钮**（`Icons.add_circle_outline`）。移动端软键盘
  没有 Shift+Enter，必须有非键盘的提交入口，否则多行化了反而加不进去。
- `_ChecklistRow` 编辑态已有保存按钮（`:1157`），不用加。

不做：把清单项做成独立的富文本/块编辑——玉简清单是「一句话一条」，不是文档。

### 2.3 编辑页标题栏跟随标题（item `8cd4aae5`）

现状 `jade_slip_editor_screen.dart:683` 是 `title: Text(l10n.jadeSlip_title)`，
固定显示"玉简"，新建那条玉简时用户看不出自己在编哪一条。

- 改成 `_title.text`，空串回落 `l10n.jadeSlip_untitled`。
- **用 `ValueListenableBuilder<TextEditingValue>(valueListenable: _title)` 包住
  `AppBar.title`**：`TextEditingController` 本身就是 `ValueListenable`，标题随键入
  实时更新，且只重建 AppBar 那一个 title，不触发整个编辑页 rebuild（页面里有
  ListView + 多个 Dismissible，整页 setState 代价明显）。
- `_slip == null`（加载中）时仍是 `l10n.jadeSlip_title`。
- 桌面 `embedded: true` 走的是分栏，没有 AppBar，不受影响。

## 3. 落地顺序

按清单顺序排，每项单独一个 commit：

1. 外接 agent 知道玉简（scope_card → allowlist → group context → she_service）
2. 清单项多行填写（_AddItemRow → _ChecklistRow）
3. 编辑页标题栏跟随标题

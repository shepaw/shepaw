# 储物袋文件「改内容 / 改名 / 删除」：决策记录

> 日期：2026-09-22
> 来源：玉简待办「储物袋中新建文件后，可以修改文件内容，可以删除，可以修改文件名」

## 1. 现状

`lib/screens/storage_browser_screen.dart` 的条目菜单（`_EntryAction`，:3095）已有
preview / copyPath / shareLink / export / versions / manifest / delete，
**缺 edit 与 rename**；删除（`:862 _deletePath`）本来就通，
玉简、指令集记录还各自走 `JadeSlipService` / `InstructionSetService`。

新建文件（`:1591 _createNewDocument`）落的是 `.md` / `.csv` 纯文本，
目前建完只能预览，改内容、改名都得绕到别处。

## 2. 决策

### 2.1 编辑内容：限定文本文件，不做万能编辑器

- 白名单扩展名：md/markdown/txt/csv/json/yaml/yml/xml/html/htm/log/ini/toml/cfg。
- 体积上限 1 MB（编辑要把整文件读进内存并整体回写）。
- 读入后按 UTF-8 严格解码，失败即提示「不是文本文件」，避免把二进制写坏。
- 玉简 / 指令集记录（`_BrowsedFile.isJadeSlipRecord` / `isInstructionRecord`）
  继续走各自的编辑页，不套裸文本编辑器——它们是结构化记录，直接改 JSON 会破坏派生状态。

编辑页独立成 `StoreTextEditorScreen`：读 → 编辑 → 保存。

补充（同日）：新建文档/表格后**直接进编辑器**。理由——待办的原话是「新建文件后，可以…」，
建完立刻能打字才叫「可以」；靠用户再去找菜单里的「编辑内容」等于没接上。
上传的本地文件不自动进编辑器（可能是二进制）。

### 2.2 保存：覆盖写，不新增版本 API

直接 `LocalStore.putBytes` 写回**同路径**。旧内容由 `_archiveToVersions`
自动进 `.versions`，所以「改内容」天然留历史，菜单里已有的「版本」就能回看。
不引入 draft/staging：储物袋的写入语义就是一次提交。

### 2.3 改名：走 `LocalStore.rename`，哈希现算

协议层 `StoreOp` 没有 rename（只有本机直调），所以重命名仅对本机 / master 镜像开放，
与删除同一道 `_canWrite` 闸门。

`rename` 需要目标 `sha256` + `size`：列表是 `computeHash: false`（sha256 为空），
改名是低频单次操作，直接 `store.meta()` 现算再传，不去维护一份哈希缓存。

已知限制（不这次修）：`rename` 只搬正式区文件并补 journal，
`.versions/<device>/<space>/<rel>/` 的索引**不跟随改名**，改名后旧版本历史仍在旧路径下。
先记录，等真有人靠版本找回再说。

### 2.4 删除

已有能力，不改动。本次只保证「新建的 md/csv」也在同一条删除路径上（它本来就走
`store.delete`，无需特殊处理）。

## 3. 落地顺序

1. 新增 `StoreTextEditorScreen`（读 / 编辑 / 保存）
2. 浏览器条目菜单加 `edit`（仅文本文件）与 `rename`
3. l10n 补「重命名 / 文件名 / 编辑」等文案
4. 测试：改名走 journal（delete + commit）、编辑保存产生版本

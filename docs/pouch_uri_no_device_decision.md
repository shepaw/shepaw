# 储物袋地址去掉设备段（决策记录）

- 日期：2026-10-16
- 状态：**已裁定，待落地**
- 关联：`docs/pouch_host_refactor_decision.md`、`docs/storage_protocol_spec.md`、`docs/storage_space_plan.md`

## 1. 问题

一份储物袋就是一个身份，主机只是当前把这份身份跑起来的机器，可以更换
（`pouch_host_refactor_decision.md` §2）。但对外地址现在是
`pouch://<space>/<device_id>/<path>`，把设备指纹写进了链接里：换一次主机，
或者由另一台工人 Hub 交出产物，链接就变了。

设备指纹标识的是**接入方**（我的手机 / 我的电脑 / 那台跑 Codex 的机器），
不是地址的一部分。

两侧都在硬校验这个段，所以不是「群树想不带」，而是通用协议本身不该带：

- App：`parseStoreUri` / `storeUriWithRef`（`lib/storage/store_protocol.dart`），
  设备段非 16 hex 直接抛 `bad_uri`。
- 主机：`crates/pouch/src/uri.rs` 的 `parse_pouch_uri`，非 16 hex 返回 `None`。

## 2. 裁定

1. **对外地址：`pouch://<space>/<path>`**，不带设备段。
2. **device 仍在帧层与存储层**：`store.*` 帧继续带 `device`，
   落盘继续按 `(device, space, path)` 组织。地址是给人/给模型看的，
   帧里的 device 是机器路由用的，两者解耦。
3. **隐含 device = 宿主 device id**：解析 `pouch://<space>/<path>` 时，
   device 取「当前把这只袋子跑起来的那台」的 device id。取值点收敛到一处。
4. **一袋一树**：用户数据只有一棵树。工人 Hub 交出来的产物写进同一棵树，
   不再各自占一棵设备树。
5. **不做兼容**：旧数据全部丢弃；存量文本里的 `pouch://` 链接不迁移。
   App 未发布，直接改到位。

## 3. device 现在用在哪（决定它后面还要不要）

用户问「这个 device id 之后在哪里使用」。当前实际用途：

| 层 | 用途 | 一袋一树后 |
|---|---|---|
| 路由（App） | `preferredReadServer` / `preferredWriteServer`：属主在线找属主，否则找 master 镜像 | 只有一台宿主，路由退化成本机 |
| 镜像（App） | `<device_id>/*` 镜像到 master；`.versions/<device>/…` 版本目录 | 无第二台设备要镜像 |
| ACL（App） | `isOwnerCrossWritable`、分享白名单按 peer 判定 | 与 device 段无关（白名单认 peer，不认 URI 里的 device） |
| 统计（App） | 用量按 device 拆分 | 只有一台，维度空转 |
| 存储（主机） | SQLite `PRIMARY KEY (device, space, path)`；磁盘 `<root>/<device>/…`；`MAX_UPLOADS_PER_DEVICE` | 只剩「产自哪台机器」的溯源字段 |
| 接入（主机） | 帧里 `device` 与 `hub_device` 比对，区分本人设备与工人 Hub | 仍需要，用来决定往哪棵树写 |

结论：一袋一树成立之后，device 不再承担路由与镜像职责，**只剩溯源字段**。
本次不动它（改面太大），但可以按这个方向在后续单独决定是否彻底删掉。

## 4. 影响面

- App：`lib/storage/store_protocol.dart`（解析 / 生成 / `isAddressableStoreDevice`），
  以及全仓 `pouch://` 字面量 —— `lib/` 约 203 处、`test/` 约 207 处。
- 主机：`crates/pouch/src/uri.rs`（`parse_pouch_uri` / `format_pouch_uri`），
  调用点约 38 处（`crates/api`、`crates/cli`、`crates/pouch`）。
- 存储层（两侧）本次不动：帧与磁盘继续带 device。

## 5. 落地步骤

1. 改协议形态：`parseStoreUri` / `storeUriWithRef` 与主机 `uri.rs` 去掉设备段；
   帧层与 `LocalPouch` 接口不动。
2. 批产替换全仓 `pouch://` 字面量与拼接点（App + 主机）。
3. 隐含 device 的取值收敛到一个入口（宿主 device id），解析与写入都走它。
4. 跑回归：基线是全绿的，出现红就是回归。

## 6. 待定

- 群协作树是否单独成 `groups` 分区。上一轮曾按「pouchId 占设备段」给 `groups`
  开过特例，方向错了，已撤回（补丁留档 `/tmp/groups-space-reverted.patch`）。
  等地址去设备段落地后再定群树落在 `groups` 还是继续留在 `workspaces`。
- device 是否最终从存储层删掉（见 §3）。

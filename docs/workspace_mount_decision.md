# 工作区挂载 vs 摄取：两档保证（决策记录）

- 日期：2026-09-28
- 状态：**方案已定，未实现**（设计取舍，先落文档再动代码）
- 关联：`docs/storage_space_plan.md`、`docs/storage_protocol_spec.md`
- 宿主侧卡片：`agent-bridge/docs/store-pouch-card-v2-decision.md`

## 1. 问题

同一个 `workspaces` 分区，两套实现互斥：

| | Hub 托管袋 | App 袋 |
|---|---|---|
| 机制 | 软链接：`agent-hub/core/src/peer/agent-store-mapping.ts:136` `ensureWorkspaceRootSymlink` | 复制摄取：`lib/storage/folder_binding_service.dart`（单向、watcher 去抖 2s + 周期 2min 兜底） |
| 同一份？ | 是，双向即时 | 否，袋内是真副本 |
| 对 symlink 的态度 | 主动创建 | `lib/storage/local_store.dart:238-255` 见到即抛 `bad_path: symlink not allowed`（防逃逸） |

即：**Hub 在袋里造的东西，App 读到就报错。** 这不是选型偏好问题，是互操作故障。

## 2. 决策：分成两档保证，不要二选一

摄取之所以必须存在，是因为「袋之所以是袋」的能力只对真文件成立：
版本（`versions.list` / `@v<n>` / `@<hash>`）、`SyncJournal` 镜像到 master、回收站、
`store search`、CAS 去重、软配额、ACL 可见性。软链接内容全在袋外改，不走 write 路径，
这些能力全部失效，且 master 无法跨设备跟随一条本地路径。

软链接之所以适合工作区，是因为那里的权威副本本来就是用户磁盘：编辑器每秒在存，
袋不该去拥有、版本化、镜像它。

因此：

- **A 档 · 挂载视图（`workspaces`）**：权威 = 用户磁盘。袋只保存一条挂载记录。
  读写穿透到真实文件；**不进版本、不进 journal、不镜像、不参与去重与配额**。
- **B 档 · 摄取 / 产物（`files` / `public` / `runtime`）**：袋内真文件，享受全部能力。
  要沉淀、分享、归档、跨设备的东西一律走这里（`store write`）。

两档的差别必须显式暴露给 Agent 和用户，不能用同一套语义含糊带过。

## 3. 挂载的实现方式：注册表，不是软链接

**选**：袋树内不出现 symlink，挂载关系存 `.system/mounts.json`：

```json
{
  "mounts": [
    {
      "id": "m-…",
      "space": "workspaces",
      "path": "<encoded-cwd>",
      "external": "/Users/…/workspace/shepaw/shepaw",
      "readonly": false,
      "created_at": "2026-09-28T…"
    }
  ]
}
```

read / list / stat 时解析映射；目录项带 `kind: mount` 标记。

**不选「放宽 LocalStore 允许受限 symlink」** 的理由：
1. 现有拒绝逻辑是刻意为之（防 symlink 逃逸，写路径与父目录逐级校验）；
2. Windows 无 symlink 语义，注册表才能跨平台；
3. 镜像 / 导出 / 打包这类批量操作对 symlink 的行为难以一致，注册表可以显式跳过。

Hub 侧软链接**保留**，因为它还要给非 store 消费者（MCP / `os` 工具）提供真实路径；
但建链接时必须同时写注册表，App 见到 symlink 且命中注册表时按挂载处理而不是报错（兼容期）。

## 4. 影响面（实现清单）

| 环节 | A 档挂载视图 | B 档摄取 |
|---|---|---|
| read / list | 解析注册表后穿透读取 | 袋内文件 |
| write | 穿透写入真实文件，**不进版本 / journal** | write.begin/chunk/commit 全流程 |
| delete | 默认**拒绝**（删除会动用户磁盘）；只允许显式 `--force` 或"解除挂载" | 进回收站，可恢复 |
| versions / `@ref` | 不支持（返回 `unsupported_op`） | 支持 |
| 跨端镜像 | 跳过（路径只在本地有意义） | SyncJournal 镜像到 master |
| search / 配额 / 去重 | 不索引、不计配额、不去重 | 全部参与 |
| 导出 / zip | 显式跳过挂载点 | 正常打包 |

## 5. 未决问题

1. **跨设备引用工作区文件**：URI 里的绝对路径在别的设备打不开。挂载视图是否干脆
   禁止跨端引用（推荐：拒绝并提示改用 B 档产物），还是引入挂载别名。
2. **删除语义**：用户从袋里删一个挂载视图下的文件，期望是删磁盘文件还是仅隐藏？
   目前倾向"默认拒绝 + 显式 force"。
3. **卡面措辞**：v2 卡现在写「软链接挂载：改磁盘即改袋」，落地后需改为
   「挂载视图：同一份，改磁盘即改袋；不进版本、不镜像、别跨设备引用」。

## 6. 落地顺序建议

1. 注册表 schema + `LocalStore` 读路径解析（只加挂载，不改现有绑定）
2. 批量操作（镜像 / 导出 / search / 配额）显式跳过挂载点
3. Hub 建链接时写注册表；App 兼容期对 symlink 不再直接报错
4. 删除语义与卡面措辞收尾

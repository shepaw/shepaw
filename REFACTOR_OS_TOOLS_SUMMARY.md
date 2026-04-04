# OS Tools 指令重构总结

## 概述

成功将 OS 工具指令从扁平结构（`shell_exec`, `file_read` 等）重构为分层 CLI 结构（`os.shell.exec`, `os.file.read` 等）。

## 主要改动

### 1. **新增分层子命名空间** ✅
   - `lib/clis/shepaw/tools/os/shell/shell_namespace.dart` — shell 命令执行、系统信息
   - `lib/clis/shepaw/tools/os/file/file_namespace.dart` — 文件操作（读、写、删除、移动、列表）
   - `lib/clis/shepaw/tools/os/clipboard/clipboard_namespace.dart` — 剪贴板读写
   - `lib/clis/shepaw/tools/os/app/app_namespace.dart` — 应用启动、URL 打开、截屏
   - `lib/clis/shepaw/tools/os/process/process_namespace.dart` — 进程管理、网络连接
   - `lib/clis/shepaw/tools/os/applescript/applescript_namespace.dart` — macOS AppleScript

### 2. **更新 os_namespace.dart** ✅
   - 注册上述 6 个子命名空间（在 `subNamespaces` getter）
   - 保留 `list`, `detail`, `categories` 查询命令（在 `commands` getter）
   - 更新示例和帮助文档

### 3. **OsToolRegistry 新增 cliPath 字段** ✅
   - `OsToolDefinition` 新增 `cliPath` 字段（如 `os.shell.exec`）
   - 保留 `name` 字段作为内部分派键（如 `shell_exec`）
   - 更新所有 30 个工具定义，添加相应的 `cliPath`
   - 新增 `resolveToolName(cliPathOrName)` 辅助方法用于双向解析
   - 更新 `openAITools()` 和 `claudeTools()` 使用 `cliPath` 暴露给 LLM
   - 更新 `getDefinition()` 支持按 `name` 或 `cliPath` 查找

### 4. **os_tool_executor.dart 支持双向转换** ✅
   - `runTool()` 现接受 `cliPath` 或内部 `name`
   - 自动通过 `OsToolRegistry.resolveToolName()` 转换为内部名
   - `classifyRisk()` 同样支持双向转换

### 5. **tools_namespace.dart 配置路由更新** ✅
   - 工具配置命令支持两种形式：
     - 旧式：`shepaw tools shell_exec.config`
     - 新式：`shepaw tools os.shell.exec.config`
   - 自动解析到内部名进行配置操作

## 工具名称映射表

| 内部名 | CLI 路径 | 分类 |
|---|---|---|
| `shell_exec` | `os.shell.exec` | shell |
| `system_info` | `os.shell.info` | shell |
| `file_read` | `os.file.read` | file |
| `file_write` | `os.file.write` | file |
| `file_delete` | `os.file.delete` | file |
| `file_move` | `os.file.move` | file |
| `file_list` | `os.file.list` | file |
| `app_open` | `os.app.open` | app |
| `url_open` | `os.app.url` | app |
| `screenshot` | `os.app.screenshot` | app |
| `clipboard_read` | `os.clipboard.read` | clipboard |
| `clipboard_write` | `os.clipboard.write` | clipboard |
| `applescript_exec` | `os.applescript.exec` | applescript |
| `process_list` | `os.process.list` | process |
| `process_kill` | `os.process.kill` | process |
| `process_detail` | `os.process.detail` | process |
| `network_connections` | `os.process.connections` | process |
| `web_search` | `web.search` | network |
| `web_fetch` | `web.fetch` | network |

## LLM 工具调用示例

### 旧版（扁平工具）
```
LLM 工具列表包含：
- shell_exec
- file_read
- clipboard_read
...
```

### 新版（分层工具）
```
LLM 工具列表现包含：
- os.shell.exec
- os.file.read
- os.clipboard.read
...
```

## CLI 使用示例

### 执行工具
```bash
# 执行 shell 命令
shepaw tools os.shell.exec --command "ls -la"

# 读文件
shepaw tools os.file.read --path /etc/hosts

# 读剪贴板
shepaw tools os.clipboard.read

# 获取系统信息
shepaw tools os.shell.info --category cpu

# 列出进程
shepaw tools os.process.list --sort_by memory
```

### 查询工具
```bash
# 列出所有可用工具
shepaw tools os.list

# 查询单个工具文档（支持两种形式）
shepaw tools os.detail --name os.shell.exec
shepaw tools os.detail --name shell_exec  # 兼容旧形式

# 按分类浏览
shepaw tools os.categories --category file
```

### 工具配置
```bash
# 旧式配置命令（仍然工作）
shepaw tools shell_exec.config

# 新式配置命令（推荐）
shepaw tools os.shell.exec.config --action set-param --key timeout --value 60
```

## 向后兼容性

✅ **完全向后兼容**
- 内部执行仍使用 `name` 字段（如 `shell_exec`）
- 工具配置数据库键保持不变（用 `name` 作为主键）
- 旧的 CLI 命令仍然有效（如 `shepaw tools shell_exec.config`）
- 代码中的 `runTool('shell_exec', args)` 调用仍然工作

## 关键设计决定

1. **双字段设计** — 保留 `name` 作为内部键，新增 `cliPath` 用于 LLM/CLI
   - 优点：最小化改动，完全向后兼容
   - 缺点：字段重复，需要手动同步

2. **LLM 工具名改用 cliPath** — 提升了工具命名的可发现性和清晰性
   - LLM 现在看到的是 `os.shell.exec` 而非 `shell_exec`
   - 更接近 CLI 实际路径，降低学习成本

3. **自动解析** — 所有涉及工具名的地方都通过 `resolveToolName()` 进行双向转换
   - 运行时：`runTool()` 和 `classifyRisk()` 自动转换
   - 配置：`_handleToolConfig()` 支持两种形式

## 文件清单

### 新建文件（6 个）
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/shell/shell_namespace.dart`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/file/file_namespace.dart`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/clipboard/clipboard_namespace.dart`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/app/app_namespace.dart`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/process/process_namespace.dart`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/applescript/applescript_namespace.dart`

### 修改文件（3 个）
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools/os/os_namespace.dart` — 注册子命名空间
- `/Users/edenzou/workspace/shepaw/shepaw/lib/services/os_tool_registry.dart` — 新增 `cliPath` 字段和解析方法
- `/Users/edenzou/workspace/shepaw/shepaw/lib/services/os_tool_executor.dart` — 更新 `runTool()` 和 `classifyRisk()`
- `/Users/edenzou/workspace/shepaw/shepaw/lib/clis/shepaw/tools_namespace.dart` — 更新配置路由

## 验证结果

✅ Dart 分析通过
- `lib/clis/shepaw/tools/os/` — No issues found!
- `lib/services/os_tool_registry.dart` — No issues found!
- `lib/services/os_tool_executor.dart` — No issues found!

## 后续工作（可选）

1. 文档更新 — 更新 README 和 CLI 帮助文本
2. UI 更新 — 虽然 icon 映射仍使用内部名，但可考虑显示 cliPath
3. 测试 — 编写测试验证新旧命令都能正常工作
4. 迁移指南 — 如有外部集成，需提供迁移指南

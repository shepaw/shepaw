# ShePaw CLI Namespace Architecture

## Overview

ShePaw CLI 是 She 的内嵌命令行接口，用于查询和管理 She 的内部状态、对话、工具和能力。

通过 CLI 统一入口，可以：
- 减少 LLM tool 定义的复杂度
- 按需加载不同的工具集，节省 token
- 提供清晰的分层结构，便于扩展和维护

## 命名空间分类体系

当前采用**按功能职责分类**的方案，将命名空间分为 4 个层级：

### 🧠 CONTEXT 层 - She 的内部状态

关于 She 本身的档案、记忆和认知。

| 命名空间 | 文件位置 | 职责 | 子命令 |
|---------|---------|------|--------|
| `profile` | `profile/` | She 的档案信息 | fields, query, write, delete |
| `memory` | `memory/` | She 的长期记忆 | query, write, append |
| `agents` | `agents/` | 已添加的 AI 助手管理 | list, get, channels, messages, chat, memory-query, memory-write, cognition-query, cognition-write |

**CLI 示例**：
```bash
shepaw profile fields
shepaw profile query
shepaw memory query --keys soul,background
shepaw agents list --status online
shepaw agents chat --id agent-123 --message "hello"
```

### 💬 COMMUNICATION 层 - 实时对话和通信

关于频道、消息、Agent 交互的通信管理。

| 命名空间 | 文件位置 | 职责 | 备注 |
|---------|---------|------|------|
| `channels` | `channels_namespace.dart` | 频道列表和元数据 | 无子命令，直接执行 |
| `messages` | `messages/` | 消息查询和过滤 | query |

**CLI 示例**：
```bash
shepaw channels               # 列出所有频道
shepaw messages query --channel abc123 --limit 10
```

> **设计注意**：Agent chat 功能在 `agents` 命名空间中（`agents chat`），因为它属于 Agent 管理的一部分。

### 🔧 TOOLING 层 - 系统工具和功能能力

关于本地工具、LLM 技能、功能模块。

| 命名空间 | 文件位置 | 职责 | 子命令 |
|---------|---------|------|--------|
| `tools` | `tools_namespace.dart` | OS 工具、文件操作等本地能力 | list, detail, categories |
| `skills` | `skills_namespace.dart` | 已加载的 LLM 技能库 | list, load, detail |

**CLI 示例**：
```bash
shepaw tools list                    # 列出所有工具
shepaw tools detail --name file_read
shepaw skills list                   # 列出所有技能
shepaw skills load --name extract_pdf
```

> **设计选择**：
> - `tools` = 本地执行能力（文件、进程、网络等）
> - `skills` = LLM 可调用的技能模块（PDF 提取、数学求解等）

### ℹ️ META 层 - 系统元信息和诊断

关于系统本身的信息、版本、能力总结、性能诊断。

| 命名空间 | 文件位置 | 职责 | 子命令 |
|---------|---------|------|--------|
| `system` | `system/` | 系统信息、工具清单、能力诊断 | info, tools-list, tools-detail, capabilities |
| `datetime` | `datetime_namespace.dart` | 当前时间和时区 | （无子命令） |
| `help` | `help_namespace.dart` | 帮助文档和 CLI 指南 | （由顶层聚合） |

**CLI 示例**：
```bash
shepaw system info                  # 应用版本、平台信息
shepaw system tools-list            # 工具总清单
shepaw system capabilities          # 系统能力总结
shepaw datetime                     # 当前时间和时区
shepaw help                         # CLI 帮助
```

## 架构图

```
                    shepaw CLI
                        |
          +-----------+---------+---------+
          |                               |
       CONTEXT 层              COMMUNICATION 层        TOOLING 层         META 层
       (She 内部)               (实时通信)             (工具能力)        (系统信息)
          |                       |                      |                |
    +-----+-----+------+      +----+-----+          +-----+------+    +---+-----+--+
    |           |      |      |          |          |            |    |       |   |
 profile    memory  agents  channels  messages    tools       skills datetime help
            query   list              query        |            |       |     |
            write   get               agent        detail     load    (无)  (聚合)
           append  channels          messages      list       list
                   messages                       category    detail
                   chat
                   memory-*
                   cognition-*
```

## 扩展规划

### 短期（Phase 4-5）

#### tools 分层结构
```
tools/
├── os/              # 文件、进程、网络、系统命令
├── media/           # 图像、音频、视频处理
└── integrations/    # API、数据库、存储集成
```

CLI 使用：
```bash
shepaw tools os file --action read --path /tmp
shepaw tools media image --action convert
shepaw tools integrations api --method GET --url ...
```

#### skills 分层结构
```
skills/
├── reasoning/       # 推理、数学、逻辑
├── extraction/      # 信息提取、NLP、PDF 解析
└── generation/      # 文本生成、代码生成
```

CLI 使用：
```bash
shepaw skills reasoning math --expression "2+2"
shepaw skills extraction pdf --action parse
shepaw skills generation code --language python
```

### 中期（Phase 6+）

- 动态加载机制（`shepaw tools load --plugin my_plugin`）
- 工具版本管理
- 工具依赖解析
- 权限和安全控制

## 命名空间注册表

当前 ShepawCLI 的命名空间注册（见 `shepaw_cli.dart`）：

```dart
late final Map<String, CliNamespace> _namespaces = {
  // CONTEXT 层
  'profile': ProfileNamespace.instance,
  'memory': MemoryNamespace.instance,
  'agents': AgentsNamespace.instance,
  
  // COMMUNICATION 层
  'channels': ChannelsNamespace.instance,
  'messages': MessagesNamespace.instance,
  
  // TOOLING 层
  'tools': ToolsNamespace.instance,
  'skills': SkillsNamespace.instance,
  
  // META 层
  'system': SystemNamespace.instance,
  'datetime': DatetimeNamespace.instance,
  'help': HelpNamespace.instance,
};
```

## 向后兼容性

### 现有 LLM Tool Definition

LLM 看到的 `namespace` 枚举包含所有 11 个命名空间。重构过程中，需要：

1. **Phase 1-2**: 保持所有现有命名空间，新增 `context` 和 `chat` 作为别名或聚合器
2. **Phase 3**: 逐步标记旧命名空间为 deprecated
3. **Phase 4+**: 在不同 LLM 工具集中选择性激活

### 迁移路径

```
旧命令                       新命令（等价）
shepaw profile query    ->   shepaw context profile query
shepaw memory write     ->   shepaw context memory write
shepaw agents list      ->   shepaw context agents list
shepaw channels         ->   shepaw chat channels
shepaw messages query   ->   shepaw chat messages query
```

> 向后兼容期间，旧命令继续可用，直到 v2.0。

## 文件组织

```
lib/clis/
├── cli_base.dart                          # 基类定义
└── shepaw/
    ├── NAMESPACE_ARCHITECTURE.md          # 本文档
    ├── shepaw_cli.dart                    # 主入口和注册表
    ├── cli_constants.dart                 # CLI 常量定义（TBD）
    │
    ├── profile/                           # CONTEXT 层
    ├── memory/
    ├── agents/
    │
    ├── channels_namespace.dart            # COMMUNICATION 层
    ├── messages/
    │
    ├── tools_namespace.dart               # TOOLING 层
    ├── skills_namespace.dart
    │
    ├── system/                            # META 层
    ├── datetime_namespace.dart
    └── help_namespace.dart
```

## 设计原则

1. **单一职责** - 每个命名空间职责清晰，不做越界之事
2. **分层隔离** - 不同层级的命名空间相对独立
3. **向后兼容** - 重构过程平滑过渡，避免破坏
4. **易于扩展** - 新工具/技能按分类自然添加到对应层级
5. **Token 节省** - 通过分层，可按需激活不同工具集给 LLM

## 相关文件

- `cli_base.dart` - CliNamespace 和 CliCommand 基类
- `shepaw_cli.dart` - ShepawCLI 主类和命名空间注册
- 各命名空间实现文件

## 相关 Issue/PR

（待填充）

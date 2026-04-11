# 项目文档索引

## 概述
本索引用于快速导航所有与 Agent/Chat 系统相关的架构文档。

## 📚 核心文档

### 1. 🏗️ PROJECT_ARCHITECTURE_EXPLORATION.md
**用途**: 完整的项目结构和架构深度分析
**适合**: 需要全面理解系统架构的开发者
**包含内容**:
- 项目类型和技术栈
- 完整的根目录结构
- 所有核心 Agent/Chat 相关文件详细清单
- ACP 协议实现细节
- 完整的超时和限制规格
- 文件依赖关系
- 完整的模型定义清单
- 服务分类和职责

**关键数据**:
- **工具调用循环限制**: `maxToolRounds = 10` (agent_messaging_service.dart:840)
- **ACP 任务超时**: `Duration(seconds: 300)` (agent_messaging_service.dart:477)
- **RPC 请求超时**: `Duration(seconds: 120)` (acp_agent_connection.dart:396)
- **聊天历史限制**: 20 条消息 (agent_messaging_service.dart:754)

---

### 2. 🔀 ARCHITECTURE_FLOW_DIAGRAM.md
**用途**: 系统流程图、序列图和数据流可视化
**适合**: 需要理解消息处理流程和通信模式的开发者
**包含内容**:
- 系统级架构图
- 1:1 消息处理详细流程图
- 本地 LLM 多轮工具调用序列图
- ACP 协议通信流程图
- 配置管理层级结构

**关键流程**:
- 消息路由决策 (本地 LLM vs ACP)
- 多轮工具调用循环 (最多10轮)
- UI 工具派发机制
- 后台任务恢复机制

---

### 3. 📖 AGENT_CHAT_QUICK_REFERENCE.md
**用途**: 面向开发者的快速参考指南
**适合**: 需要快速查找 API、配置、超时值的开发者
**包含内容**:
- 5 个最关键文件的方法签名
- 超时和循环限制的表格总结
- 工具调用流程简化图
- 核心数据模型解释
- 操作示例代码
- 配置位置表格
- 协议选择逻辑
- 方法调用链文档

**快速查找**:
- 所有超时值和配置常数都整理在表格中
- 协议选择标准清晰列出
- 关键方法调用链有完整文档

---

## 🎯 核心文件快速定位

### 最关键的 5 个文件

| 文件 | 行数 | 主要功能 |
|------|------|---------|
| `lib/services/chat_service.dart` | 300+ | 整个消息系统中枢，任务生命周期管理 |
| `lib/services/messaging/agent_messaging_service.dart` | 1400+ | 1:1 Agent 消息处理，多轮工具调用循环 |
| `lib/services/local_llm_agent_service.dart` | 1000+ | 直接 LLM HTTP API 调用 |
| `lib/services/acp_agent_connection.dart` | 700+ | WebSocket 连接管理和 JSON-RPC 2.0 |
| `lib/services/messaging/local_llm_handler.dart` | 285 | 本地 LLM 工具构建和消息格式化 |

### 完整文件列表

**消息和通信服务**:
- `lib/services/chat_service.dart`
- `lib/services/messaging/agent_messaging_service.dart`
- `lib/services/messaging/group_agent_executor.dart`
- `lib/services/messaging/local_llm_handler.dart`
- `lib/services/local_llm_agent_service.dart`
- `lib/services/acp_agent_connection.dart`

**ACP 协议**:
- `lib/models/acp_protocol.dart`
- `lib/services/acp_hub_handlers.dart`

**配置和注册表**:
- `lib/services/skill_registry.dart`
- `lib/services/model_registry.dart`
- `lib/services/ui_component_registry.dart`
- `lib/config/app_config.dart`

**任务和流程**:
- `lib/services/task/task_models.dart`
- `lib/services/flow_executor.dart`

**数据模型**:
- `lib/models/message.dart`
- `lib/models/llm_stream_event.dart`
- `lib/models/attachment_data.dart`

---

## 🔑 关键概念

### 工具调用循环 (Tool Calling Loop)

**最大轮数**: 10 (可配置)
**位置**: `lib/services/messaging/agent_messaging_service.dart:840`

```dart
for (int round = 0; round < maxToolRounds; round++) {
  // 执行 LLM 调用
  // 收集工具结果
  // 检查是否完成
}
```

**循环终止条件**:
1. `stop_reason == "end_turn"` (LLM 主动停止)
2. UI 工具被调用 (fire-and-forget)
3. 达到最大轮数 (10)
4. 用户取消任务

### 超时机制

| 超时类型 | 值 | 说明 |
|---------|-----|------|
| RPC 请求超时 | 120 秒 | 单个 ACP 请求 (acp_agent_connection.dart:396) |
| ACP 任务超时 | 300 秒 | 整个 agent.chat 任务 (agent_messaging_service.dart:477) |
| 心跳间隔 | 30 秒 | ACP 连接心跳 (acp_agent_connection.dart:139) |

### 协议选择

**本地 LLM** 条件:
- Agent 类型为 `local_llm`
- 配置中启用了本地 LLM

**ACP 协议** 条件:
- Agent 类型为 `remote`
- 通过 WebSocket 连接到远程 Agent
- 支持双向 JSON-RPC 2.0 通信

---

## 📊 数据流

### 1:1 消息流程

```
用户消息
  ↓
ChatService.sendMessageToAgent()
  ↓
AgentMessagingService.sendMessageToAgent()
  ↓
选择协议 (Local LLM vs ACP)
  ↓
多轮工具调用循环 (最多10轮)
  ↓
保存到数据库
  ↓
UI 更新
```

### 工具调用流程

```
LLM 响应 (包含工具调用)
  ↓
分类工具类型:
  - UI 工具 → 派发到 UI (结束循环)
  - 可执行工具 → 执行 → 继续循环
  - get_tool_result → 检索缓存 → 继续循环
  ↓
收集工具结果
  ↓
下一轮 LLM 调用
```

---

## 🔍 查找信息

### 我想了解...

- **整个系统如何运作** → 读 `ARCHITECTURE_FLOW_DIAGRAM.md`
- **某个服务的所有方法** → 搜 `PROJECT_ARCHITECTURE_EXPLORATION.md`
- **超时配置在哪里** → 查 `AGENT_CHAT_QUICK_REFERENCE.md` 中的"超时和限制"表
- **工具调用循环如何工作** → 查 `ARCHITECTURE_FLOW_DIAGRAM.md` 中的"多轮工具调用"图
- **某个文件的完整代码** → 用 Read 工具打开源文件
- **找到特定字符串在哪个文件** → 用 Grep 工具搜索

---

## 📝 使用建议

1. **首次了解项目**: 按顺序读
   - ARCHITECTURE_FLOW_DIAGRAM.md (整体流程)
   - AGENT_CHAT_QUICK_REFERENCE.md (关键概念和 API)
   - PROJECT_ARCHITECTURE_EXPLORATION.md (详细参考)

2. **调试问题**: 
   - 先查 AGENT_CHAT_QUICK_REFERENCE.md 中的关键概念
   - 用 Grep 查找相关代码
   - 参考 ARCHITECTURE_FLOW_DIAGRAM.md 理解流程

3. **添加新功能**:
   - 理解 ARCHITECTURE_FLOW_DIAGRAM.md 中的数据流
   - 找到正确的服务 (参考 PROJECT_ARCHITECTURE_EXPLORATION.md)
   - 查看相似功能的实现

---

## 🔗 相关资源

- **README.md**: 项目整体介绍
- **BUILD_GUIDE.md**: 编译和运行指南
- **UPDATE_CHECK_***: 更新检查功能文档
- **REFACTOR_OS_TOOLS_SUMMARY.md**: OS 工具重构总结

---

## ✅ 文档维护

最后更新: 2026-04-11

这些文档基于代码库的深度分析生成。当以下内容变化时应更新:
- 工具调用循环上限 (`maxToolRounds`)
- 超时配置值
- 核心服务的主要方法
- 协议选择逻辑
- 数据流程

---

## 📞 反馈

如果您发现文档中的:
- 错误或不准确的地方
- 缺失的重要信息
- 不清楚的解释

请创建 Issue 或更新这些文档。

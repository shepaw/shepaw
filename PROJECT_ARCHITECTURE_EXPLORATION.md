# 项目结构深度探索报告

## 一、项目类型和语言
- **项目类型**: Flutter + Dart 跨平台应用
- **主要技术栈**: Flutter (UI), Dart (业务逻辑)
- **支持平台**: iOS, macOS, Android, Windows, Web
- **工作目录**: `/Users/edenzou/workspace/shepaw/shepaw`

## 二、项目整体架构

### 根目录结构
```
shepaw/
├── lib/              # Dart 源代码
├── test/             # 测试代码
├── build/            # 编译输出
├── ios/              # iOS 相关
├── android/          # Android 相关
├── macos/            # macOS 相关
├── windows/          # Windows 相关
├── web/              # Web 相关
├── cli-tools/        # CLI 工具源码
├── docs/             # 文档
├── assets/           # 资源文件
├── fonts/            # 字体文件
├── design/           # 设计文件
├── pubspec.yaml      # 项目依赖配置
└── pubspec.lock      # 依赖锁定文件
```

## 三、Core Agent/Chat 相关文件详细清单

### 3.1 Agent 通信和消息服务 (最核心)

#### 📍 `lib/services/chat_service.dart` (约300+ 行)
**功能**: 主聊天服务，是整个消息系统的中枢
- **关键职责**:
  - 1:1 DM 消息管理 (`sendMessageToAgent`)
  - 群组聊天编排 (`sendMessageToGroup`)
  - 活跃任务生命周期管理
  - ACP 连接池管理
  - 计划执行 (FlowExecutor)
  - 会话管理
  - 活跃任务映射: `_activeTasks` (keyed by channelId)
  - 活跃群组任务: `_activeGroupTasks` (keyed by channelId -> agentId)

- **关键类**:
  - `ActiveTask`: 追踪单个 agent 任务
  - `GroupActiveTask`: 追踪群组内单个 agent 任务
  - `HistorySupplementResult`: 历史补充结果

- **重要依赖**:
  - `AgentMessagingService`: 1:1 消息处理
  - `GroupAgentExecutor`: 群组 agent 执行
  - `FlowExecutor`: 多阶段流程执行

#### 📍 `lib/services/messaging/agent_messaging_service.dart` (约1400+ 行)
**功能**: 处理单个 agent 的 1:1 消息发送和接收

- **核心方法**:
  - `sendMessageToAgent()`: 主入口
    - 参数: content, agent, userId, userName, etc.
    - 返回: Future<Message?>
    - 支持 ACP WebSocket 和本地 LLM 两种协议

- **关键子方法**:
  - `_sendViaACPProtocol()`: ACP WebSocket 协议处理
    - **超时配置**: `const Duration(seconds: 300)` (5分钟)
    - 等待 `task.completed` 或 `task.error` 事件
    - 支持取消和后台恢复

  - `_sendViaLocalLLM()`: 本地 LLM 处理 (带多轮工具调用)
    - **关键参数**:
      - `const maxToolRounds = 10` (最多10轮)
      - 支持 Claude/OpenAI 格式
      - 支持 UI 工具、技能工具、工具模型
    
    - **工具调用循环** (第842-1080行):
      ```dart
      const maxToolRounds = 10;  // ← 关键限制
      for (int round = 0; round < maxToolRounds; round++) {
        // 执行 LLM 一轮 (chatRound)
        // 收集文本事件、工具调用事件、完成事件
        // 处理 UI 工具 (中断循环)
        // 处理 get_tool_result (继续循环)
        // 处理可执行工具 (执行后继续循环)
      }
      ```

  - `_sendViaLocalLLMSingleRound()`: 无工具的单轮对话

- **工具执行流程**:
  1. 分离 UI 工具、技能工具、工具模型工具、PAW CLI 工具
  2. UI 工具: 立即派发 (fire-and-forget, 中断循环)
  3. 可执行工具: 执行并收集结果
  4. 附加工具结果到消息历史
  5. 继续下一轮 (最多10轮)

#### 📍 `lib/services/messaging/local_llm_handler.dart` (约285 行)
**功能**: 本地 LLM 工具调用的辅助函数

- **关键函数**:
  - `buildToolList()`: 构建工具列表 (Claude/OpenAI 格式)
  - `buildSystemPrompt()`: 构建系统提示
  - `appendToolRoundOpenAI()`: 追加工具轮 (OpenAI 格式)
  - `appendToolRoundClaude()`: 追加工具轮 (Claude 格式)
  - `dispatchUiToolCall()`: 派发 UI 工具调用
  - `getToolResultOpenAI()` / `getToolResultClaude()`: get_tool_result 工具定义

### 3.2 Agent 连接和 ACP 协议

#### 📍 `lib/services/acp_agent_connection.dart` (约700+ 行)
**功能**: 管理单个 agent 的 WebSocket 连接，实现 ACP JSON-RPC 2.0 协议

- **关键类**:
  - `ACPCancellationToken`: 取消令牌
    - 方法: `cancel()`, `bind()`, `get isCancelled`
    - 当取消时向 agent 发送 `agent.cancelTask` 请求

  - `TaskCallbacks`: 每个任务的回调束
    - onTextContent, onActionConfirmation, onSingleSelect, etc.

  - `ACPAgentConnection`: WebSocket 连接管理
    - **超时配置**: `const Duration(seconds: 120)` (2分钟) 用于请求
    - **心跳配置**: `heartbeatIntervalSeconds = 30` (默认)
    - **重连配置**: 
      - `autoReconnect = true`
      - `reconnectDelayMs = 3000`
      - `maxReconnectAttempts = 5`
      - `maxHeartbeatFailures = 3`

- **关键方法**:
  - `connect()`: 连接到 agent
  - `sendRequest()`: 发送 RPC 请求 (带120秒超时)
  - `agent.chat()`: 发送聊天请求
  - `agent.cancelTask()`: 取消任务
  - `_handleIncomingMessage()`: 处理来自 agent 的消息

#### 📍 `lib/models/acp_protocol.dart` (约150 行)
**功能**: ACP 协议的数据模型

- **关键类**:
  - `ACPRequest`: JSON-RPC 2.0 请求
  - `ACPResponse`: JSON-RPC 2.0 响应
  - `ACPError`: 错误信息

### 3.3 本地 LLM 服务

#### 📍 `lib/services/local_llm_agent_service.dart` (约1000+ 行)
**功能**: 直接调用 LLM HTTP API，支持流式响应

- **关键方法**:
  - `chat()`: 单轮对话流式方法
    - 支持 Claude、OpenAI、GLM 三种格式
    - 返回 `Stream<LLMStreamEvent>`

  - `chatRound()`: 多轮工具调用的单轮执行
    - 参数: messages, tools, systemPrompt
    - 返回: `Stream<LLMStreamEvent>`

- **支持的格式**:
  - Claude (Anthropic API): `/messages` endpoint
  - OpenAI: `/chat/completions` endpoint
  - GLM (OpenAI 兼容): `/chat/completions` endpoint

- **流事件类型**:
  - `LLMTextEvent`: 文本块
  - `LLMToolCallEvent`: 工具调用
  - `LLMDoneEvent`: 完成 (包含 stopReason 和 rawAssistantMessage)

#### 📍 `lib/models/llm_stream_event.dart` (约47 行)
**功能**: LLM 流式事件类型定义

- **事件类型**:
  ```dart
  sealed class LLMStreamEvent {}
  class LLMTextEvent extends LLMStreamEvent
  class LLMToolCallEvent extends LLMStreamEvent
  class LLMDoneEvent extends LLMStreamEvent
  ```

### 3.4 群组聊天服务

#### 📍 `lib/services/group/group_agent_executor.dart` (约500+ 行)
**功能**: 执行群组内单个 agent 的响应轮次

- **关键方法**:
  - `executeGroupAgentRound()`: 执行单个 agent 一轮 (支持本地 LLM 和 ACP)
  - `buildGroupChatHistoryWithImages()`: 构建多模态历史

#### 📍 `lib/services/flow_executor.dart` (约400+ 行)
**功能**: 执行多阶段流程计划

- **关键类**:
  - `FlowExecutor`: 流程执行器
  - `FlowExecutorContext`: 流程上下文 (依赖注入容器)

- **关键方法**:
  - `execute()`: 执行流程的所有阶段
  - `pause()` / `resume()`: 暂停/恢复
  - `resumeWithInteractionResult()`: 处理用户交互结果

#### 📍 `lib/services/group/group_orchestration_service.dart`
**功能**: 群组消息路由和编排

#### 📍 `lib/services/group/group_dispatch_parser.dart`
**功能**: 解析结构化 JSON 派发块

#### 📍 `lib/services/group/group_prompt_builder.dart`
**功能**: 构建群组系统提示和多模态检测

### 3.5 任务和计划相关

#### 📍 `lib/services/task/task_models.dart` (约100 行)
**功能**: 活跃任务模型

- **关键类**:
  - `ActiveTask`: 1:1 任务追踪
    - 字段: taskId, agentId, agentName, channelId, userMessageId, userId, userName
    - 回调: onStreamChunk, onActionConfirmation, onSingleSelect, etc.
    - 完成器: dbSaveCompleter (等待 DB 保存完成)

  - `GroupActiveTask`: 群组内 agent 任务追踪
    - 字段: agentId, agentName, channelId
    - 简化的回调集合

#### 📍 `lib/services/task/plan_approval_service.dart`
**功能**: 计划批准管理

### 3.6 配置和常量

#### 📍 `lib/config/app_config.dart` (约60 行)
**功能**: 环境配置

- **配置类型**:
  - `development`: 本地开发 (http://localhost:3002)
  - `staging`: 测试环境
  - `production`: 生产环境

- **配置项**: apiBaseUrl, wsBaseUrl, environment, enableLogging, enableCrashReporting

### 3.7 控制器

#### 📍 `lib/controllers/chat_controller.dart`
**功能**: UI 层和业务逻辑的连接

## 四、工具调用循环和限制详解

### 4.1 工具调用限制

| 限制项 | 值 | 位置 | 说明 |
|-------|-----|------|------|
| **maxToolRounds** | 10 | `agent_messaging_service.dart:840` | 本地 LLM 多轮工具调用最多循环次数 |
| **ACP 请求超时** | 120秒 | `acp_agent_connection.dart:395-396` | 单个 RPC 请求的超时时间 |
| **ACP 任务超时** | 300秒 | `agent_messaging_service.dart:476-477` | 整个 ACP 任务的总超时时间 |
| **心跳间隔** | 30秒 | `acp_agent_connection.dart:139` | ACP 连接心跳周期 |
| **最大心跳失败** | 3 | `acp_agent_connection.dart:106` | 连续心跳失败次数达到该值会重连 |
| **最大重连次数** | 5 | `acp_agent_connection.dart:112` | 重连尝试最多次数 |
| **重连延迟** | 3000ms | `acp_agent_connection.dart:110` | 重连尝试间隔 |

### 4.2 本地 LLM 工具调用流程图

```
sendViaLocalLLM()
  ├─ 检查是否有工具
  └─ 多轮循环 (maxToolRounds = 10)
      ├─ Round 1..10:
      │   ├─ 调用 chatRound()
      │   ├─ 收集事件: 文本、工具调用、完成
      │   ├─ 分类工具:
      │   │   ├─ UI 工具 → 派发 (中断)
      │   │   ├─ get_tool_result → 查库 (继续)
      │   │   ├─ 技能工具 → 执行 (继续)
      │   │   ├─ 工具模型 → 执行 (继续)
      │   │   └─ PAW CLI → 执行 (继续)
      │   └─ 无工具调用 → 中断
      └─ 创建最终消息并保存
```

### 4.3 ACP 任务流程

```
sendViaACPProtocol()
  ├─ 创建 ACP 连接
  ├─ 创建 ActiveTask
  ├─ 发送 agent.chat 请求
  ├─ 等待 task.completed/task.error (最多300秒)
  ├─ 处理取消 (acpCancellationToken)
  └─ 返回响应消息
```

## 五、关键数据流

### 5.1 单 Agent 1:1 消息流

```
用户消息
  ↓
ChatService.sendMessageToAgent()
  ↓
保存用户消息到 DB
  ↓
AgentMessagingService.sendMessageToAgent()
  ├─ 是否本地 LLM?
  │  ├─ 是 → _sendViaLocalLLM()
  │  │   ├─ 多轮工具调用循环
  │  │   └─ 保存工具执行结果到 DB
  │  └─ 否 → ACP 检查
  └─ _sendViaACPProtocol() (ACP 协议)
      ├─ WebSocket 连接
      ├─ 等待 task.completed
      └─ 处理 UI 工具回调
  ↓
保存 Agent 响应到 DB
  ↓
更新 UI & 前景任务服务
```

### 5.2 群组消息流

```
用户消息
  ↓
ChatService.sendMessageToGroup()
  ↓
GroupDispatchParser (解析派发块)
  ↓
FlowExecutor (执行多阶段计划)
  ├─ 遍历每个 Stage
  └─ 对每个 Agent 调用 GroupAgentExecutor
      ├─ 本地 LLM 路径
      └─ ACP 路径
  ↓
所有 Agent 完成
  ↓
保存所有响应到 DB
```

## 六、关键文件依赖关系

```
ChatService
  ├─ AgentMessagingService
  │   ├─ LocalLLMAgentService
  │   ├─ ACPAgentConnection
  │   └─ LocalLLMHelpers
  ├─ GroupAgentExecutor
  │   ├─ LocalLLMAgentService
  │   └─ ACPAgentConnection
  ├─ FlowExecutor
  ├─ GroupOrchestrationService
  └─ GroupSessionService

LocalLLMAgentService
  └─ LLMStreamEvent (LLMTextEvent, LLMToolCallEvent, LLMDoneEvent)

ACPAgentConnection
  ├─ ACPRequest/ACPResponse/ACPError
  ├─ TaskCallbacks
  └─ ACPCancellationToken
```

## 七、模型定义文件清单

### 消息和通信模型
- `lib/models/message.dart` - 消息模型
- `lib/models/channel.dart` - 频道/会话模型
- `lib/models/remote_agent.dart` - 远程 Agent 定义
- `lib/models/acp_protocol.dart` - ACP 协议模型
- `lib/models/acp_server_message.dart` - ACP 服务器消息
- `lib/models/agent_conversation_request.dart` - Agent 对话请求

### LLM 和工具模型
- `lib/models/llm_stream_event.dart` - LLM 流事件
- `lib/models/llm_provider_config.dart` - LLM 提供者配置
- `lib/models/model_definition.dart` - 模型定义
- `lib/models/model_routing_config.dart` - 模型路由配置
- `lib/models/tool_execution_result.dart` - 工具执行结果
- `lib/models/tool_config.dart` - 工具配置
- `lib/models/inference_log_entry.dart` - 推理日志

### 任务和计划模型
- `lib/models/planning_models.dart` - 计划执行相关模型
- `lib/models/trace_models.dart` - 追踪模型

### 其他模型
- `lib/models/agent.dart` - Agent 通用模型
- `lib/models/attachment_data.dart` - 附件数据
- `lib/models/mention_entry.dart` - @提及条目
- `lib/models/user.dart` - 用户模型

## 八、服务文件按功能分类

### 核心聊天服务
- `chat_service.dart` - 主聊天服务
- `messaging/agent_messaging_service.dart` - 1:1 消息处理
- `messaging/local_llm_handler.dart` - 本地 LLM 工具处理
- `local_llm_agent_service.dart` - 本地 LLM API 调用

### Agent 连接和通信
- `acp_agent_connection.dart` - ACP WebSocket 连接
- `acp_server_service.dart` - ACP 服务器
- `acp_hub_handlers.dart` - ACP Hub 请求处理

### 群组聊天
- `group/group_agent_executor.dart` - 群组 agent 执行
- `group/group_orchestration_service.dart` - 群组编排
- `group/group_dispatch_parser.dart` - 派发解析
- `group/group_prompt_builder.dart` - 提示构建
- `group/group_interaction_handler.dart` - 交互处理
- `group/group_session_service.dart` - 会话管理
- `group/planning_helpers.dart` - 计划辅助函数

### 任务和计划
- `task/task_models.dart` - 任务模型
- `task/plan_approval_service.dart` - 计划批准
- `flow_executor.dart` - 流程执行

### 数据库和存储
- `local_database_service.dart` - 本地数据库
- `tool_result_database_service.dart` - 工具结果存储
- `trace_database_service.dart` - 追踪数据库
- `she_profile_database_service.dart` - She Agent Profile DB

### 日志和追踪
- `inference_log_service.dart` - 推理日志
- `trace_service.dart` - 追踪服务
- `logger_service.dart` - 日志服务

### 会话管理
- `session/session_history_service.dart` - 会话历史

### 其他服务
- `remote_agent_service.dart` - 远程 Agent 服务
- `agent_memory_biz_service.dart` - Agent 记忆业务逻辑
- `agent_memory_db_service.dart` - Agent 记忆数据库
- `agent_prompt_builder.dart` - Agent 提示构建
- `agent_collaboration_service.dart` - Agent 协作

## 九、关键配置和常数总结

| 配置项 | 值 | 文件 | 用途 |
|-------|-----|------|------|
| maxToolRounds | 10 | agent_messaging_service.dart | 本地LLM多轮工具调用限制 |
| ACP_REQUEST_TIMEOUT | 120秒 | acp_agent_connection.dart | RPC请求超时 |
| ACP_TASK_TIMEOUT | 300秒 | agent_messaging_service.dart | 整个任务超时 |
| HEARTBEAT_INTERVAL | 30秒 | acp_agent_connection.dart | 心跳周期 |
| MAX_HEARTBEAT_FAILURES | 3 | acp_agent_connection.dart | 心跳失败重连阈值 |
| MAX_RECONNECT_ATTEMPTS | 5 | acp_agent_connection.dart | 最大重连次数 |
| RECONNECT_DELAY | 3000ms | acp_agent_connection.dart | 重连间隔 |
| CHAT_HISTORY_LIMIT | 20 | agent_messaging_service.dart | 加载的聊天历史条数 |

## 十、总结

### 架构特点
1. **双协议支持**: ACP (WebSocket JSON-RPC) 和本地 LLM (HTTP API)
2. **多轮工具调用**: 本地 LLM 支持最多10轮工具调用循环
3. **活跃任务管理**: 任务可在后台继续执行 (即使 UI 离开)
4. **流程执行**: 支持多阶段并发群组执行
5. **取消支持**: 全链路取消令牌支持

### 核心限制
- 工具调用轮数: **10轮**
- 单个请求超时: **120秒** (ACP)
- 整个任务超时: **300秒** (ACP)
- 心跳间隔: **30秒**

### 关键类和方法
- `ChatService.sendMessageToAgent()` - 主入口 (DM)
- `ChatService.sendMessageToGroup()` - 主入口 (群组)
- `AgentMessagingService._sendViaLocalLLM()` - 本地LLM处理 (包含工具循环)
- `ACPAgentConnection.sendRequest()` - ACP 请求 (120秒超时)
- `LocalLLMAgentService.chatRound()` - LLM 单轮调用

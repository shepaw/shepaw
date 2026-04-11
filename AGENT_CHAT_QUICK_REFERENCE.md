# Agent/Chat 系统快速参考指南

## 🎯 五大核心文件（优先级排序）

### 1️⃣ 消息路由中枢
**文件**: `lib/services/chat_service.dart`
```dart
// 1:1 消息入口
Future<Message?> sendMessageToAgent(...)

// 群组消息入口  
Future<void> sendMessageToGroup(...)
```

### 2️⃣ 单Agent消息处理
**文件**: `lib/services/messaging/agent_messaging_service.dart`
```dart
// 主方法：支持ACP和本地LLM两种协议
Future<Message?> sendMessageToAgent(...)

// 私有方法：本地LLM多轮工具调用 (10轮限制在这里!)
Future<Message?> _sendViaLocalLLM(...)  // ← maxToolRounds = 10

// 私有方法：ACP WebSocket协议
Future<Message?> _sendViaACPProtocol(...)  // ← 300秒超时
```

### 3️⃣ 本地LLM服务
**文件**: `lib/services/local_llm_agent_service.dart`
```dart
// 单轮对话流
Stream<LLMStreamEvent> chat(...)

// 多轮工具调用单轮执行
Stream<LLMStreamEvent> chatRound(...)  // 返回文本、工具调用、完成事件
```

### 4️⃣ ACP连接管理
**文件**: `lib/services/acp_agent_connection.dart`
```dart
// 发送RPC请求 (120秒超时)
Future<ACPResponse> sendRequest(...)  // ← Duration(seconds: 120)

// 连接到agent
Future<void> connect(...)

// 取消任务
Future<ACPResponse> cancelTask(...)
```

### 5️⃣ 工具调用辅助
**文件**: `lib/services/messaging/local_llm_handler.dart`
```dart
// 工具调用循环中的关键函数
static void dispatchUiToolCall(...)
static void appendToolRoundOpenAI(...)
static void appendToolRoundClaude(...)
```

---

## ⏱️ 超时和循环限制

### 工具调用限制
```dart
// ❌ 本地LLM工具调用：最多10轮
lib/services/messaging/agent_messaging_service.dart:840
const maxToolRounds = 10;
for (int round = 0; round < maxToolRounds; round++) { ... }
```

### 时间限制
| 限制 | 值 | 位置 |
|-----|-----|------|
| **ACP请求超时** | 120秒 | `acp_agent_connection.dart:396` |
| **ACP任务总超时** | 300秒 | `agent_messaging_service.dart:477` |
| **心跳间隔** | 30秒 | `acp_agent_connection.dart:139` |

---

## 🔄 工具调用流程

### 本地LLM多轮工具调用流程
```
_sendViaLocalLLM()
  │
  ├─ 检查是否有工具
  │  └─ 无工具 → _sendViaLocalLLMSingleRound() 单轮返回
  │
  ├─ 有工具 → 进入多轮循环 (const maxToolRounds = 10)
  │
  └─ for (round 0..9):
      ├─ chatRound() 执行一轮
      ├─ 收集事件: LLMTextEvent, LLMToolCallEvent, LLMDoneEvent
      ├─ 分类工具:
      │  ├─ UI工具 → dispatchUiToolCall() [中断循环]
      │  ├─ get_tool_result → 查库 [继续循环]
      │  ├─ 技能工具 → 执行 [继续循环]
      │  ├─ 工具模型 → 执行 [继续循环]
      │  └─ PAW CLI → 执行 [继续循环]
      ├─ appendToolRound*() 添加结果到消息历史
      └─ 无工具调用 → 中断循环
```

### ACP协议任务流程
```
sendViaACPProtocol()
  │
  ├─ _getOrCreateACPConnection() → ACPAgentConnection
  ├─ 创建 ActiveTask
  ├─ registerTaskCallbacks()
  │
  ├─ connection.agent.chat() 发送请求
  │
  ├─ 等待 taskCompleter.future.timeout(Duration(seconds: 300))
  │  ├─ 接收 task.completed → 成功
  │  ├─ 接收 task.error → 失败
  │  └─ 超过300秒 → TimeoutException
  │
  ├─ 处理回调事件 (UI工具、文本、元数据等)
  └─ 返回 Message
```

---

## 🔌 核心数据模型

### ActiveTask（1:1 任务追踪）
```dart
// 位置: lib/services/task/task_models.dart
class ActiveTask {
  String taskId;
  String agentId, agentName;
  String channelId;
  String accumulatedContent;
  bool isComplete;
  
  // 回调（UI离开时会置为null）
  Function(String)? onStreamChunk;
  Function(Map)? onActionConfirmation;
  // ...等等
  
  // 等待DB保存完成
  Completer<void> dbSaveCompleter;
}
```

### LLMStreamEvent（流式事件）
```dart
// 位置: lib/models/llm_stream_event.dart
sealed class LLMStreamEvent {}

class LLMTextEvent extends LLMStreamEvent {
  String text;
}

class LLMToolCallEvent extends LLMStreamEvent {
  String id, name;
  Map<String, dynamic> arguments;
}

class LLMDoneEvent extends LLMStreamEvent {
  String stopReason;  // 'stop', 'tool_calls', etc.
  Map<String, dynamic>? rawAssistantMessage;
}
```

---

## 🛠️ 常见操作

### 发送1:1消息
```dart
final message = await ChatService().sendMessageToAgent(
  content: "Hello",
  agent: remoteAgent,
  userId: userId,
  userName: userName,
  channelId: channelId,
  onStreamChunk: (chunk) => print(chunk),
  onActionConfirmation: (data) => handleConfirmation(data),
  // ...
);
```

### 发送群组消息
```dart
await ChatService().sendMessageToGroup(
  content: "Group message",
  channel: channel,
  // ...
);
```

### 取消任务
```dart
final token = ACPCancellationToken();
// 之后...
token.cancel();  // 触发取消，agent收到 agent.cancelTask RPC
```

---

## 📊 配置位置

| 配置项 | 值 | 文件 | 行号 |
|-------|-----|------|------|
| maxToolRounds | 10 | agent_messaging_service.dart | 840 |
| ACP REQUEST_TIMEOUT | 120s | acp_agent_connection.dart | 396 |
| ACP TASK_TIMEOUT | 300s | agent_messaging_service.dart | 477 |
| HEARTBEAT_INTERVAL | 30s | acp_agent_connection.dart | 139 |
| CHAT_HISTORY_LIMIT | 20 | agent_messaging_service.dart | 754 |

---

## 🎭 协议选择逻辑

```dart
// 在 AgentMessagingService.sendMessageToAgent()

if (LocalLLMAgentService.instance.isLocalAgent(agent)) {
  // ✅ 本地LLM路径：支持多轮工具调用
  return await _sendViaLocalLLM(...);
  
} else if (agent.protocol == ProtocolType.acp) {
  // ✅ ACP协议路径：WebSocket JSON-RPC
  return await _sendViaACPProtocol(...);
  
} else {
  // ✅ 通用HTTP路径
  return await _sendViaGenericProtocol(...);
}
```

---

## 🔑 关键方法调用链

```
ChatService
  ├─ sendMessageToAgent()
  └─ AgentMessagingService
      ├─ sendMessageToAgent()
      ├─ _sendViaLocalLLM()
      │  └─ LocalLLMAgentService
      │      └─ chatRound()  ← 每轮调用
      └─ _sendViaACPProtocol()
          └─ ACPAgentConnection
              ├─ sendRequest()  ← 120秒超时
              └─ 处理回调
```

---

## ⚠️ 重要注意

1. **工具调用上限**: 本地LLM最多10轮 (硬限制)
2. **超时设置**: ACP请求120秒，整个任务300秒
3. **UI回调**: 用户离开页面时会自动detach，任务继续运行
4. **取消机制**: 通过ACPCancellationToken，发送agent.cancelTask RPC
5. **多模态支持**: Claude用base64格式，OpenAI用data URL格式


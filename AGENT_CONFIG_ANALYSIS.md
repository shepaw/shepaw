# Shepaw Agent 配置系统全面分析

## 📋 项目概览

本文档基于对以下关键文件的详细分析，总结 Shepaw 应用中 Agent 的配置体系、编辑页面结构和服务逻辑。

---

## 1. 文件位置总汇

### 核心服务文件
- **消息服务**: `/lib/services/messaging/agent_messaging_service.dart` (1437 行)
- **数据库服务**: `/lib/services/local_database_service.dart`
- **Remote Agent 服务**: `/lib/services/remote_agent_service.dart`
- **Model 注册表**: `/lib/services/model_registry.dart`
- **Skill 注册表**: `/lib/services/skill_registry.dart`

### 数据模型文件
- **Agent 模型**: `/lib/models/agent.dart` (173 行)
- **RemoteAgent 模型**: `/lib/models/remote_agent.dart` (498 行)
- **提示词配置**: `/lib/models/prompt_stack_config.dart`
- **模型定义**: `/lib/models/model_definition.dart`
- **LLM 提供商配置**: `/lib/models/llm_provider_config.dart`

### UI 页面文件
- **Agent 详情页** (旧): `/lib/screens/agent_detail_screen.dart` (388 行)
- **Remote Agent 详情页**: `/lib/screens/remote_agent_detail_screen.dart` (700+ 行)
- **添加 Remote Agent 页**: `/lib/screens/add_remote_agent_screen.dart` (700+ 行)
- **Remote Agent 列表页**: `/lib/screens/remote_agent_list_screen.dart`

---

## 2. Agent 消息服务关键配置

### 文件: `agent_messaging_service.dart`

#### 🔴 关键常数值

1. **Tool Call 循环限制** (第 840 行)
   ```dart
   const maxToolRounds = 10;
   ```
   - **含义**: 多轮工具调用的最大轮次
   - **场景**: 本地 LLM Agent 的多轮对话中，LLM 最多可以调用工具 10 次
   - **位置**: 在 `_sendViaLocalLLM()` 方法中

2. **ACP 任务超时** (第 476-480 行)
   ```dart
   await taskCompleter.future.timeout(
     const Duration(seconds: 300),
     onTimeout: () {
       throw TimeoutException('ACP task timed out');
     },
   );
   ```
   - **含义**: ACP 协议的远端 Agent 任务超时时间为 **300 秒** (5 分钟)
   - **位置**: `_sendViaACPProtocol()` 方法中

3. **聊天历史限制** (第 751、1258 行)
   ```dart
   const historyLimit = 20;
   final messages = await loadChannelMessages(sessionId, limit: historyLimit);
   ```
   - **含义**: 聊天对话历史最多保留 **20 条消息** 用于上下文
   - **场景**: 无论是本地 LLM 还是远端 ACP Agent，都会加载最近 20 条消息作为上下文
   - **位置**: `_sendViaLocalLLM()` 和 `_sendViaLocalLLMSingleRound()` 中

#### 🔧 工具调用循环逻辑 (第 812-1144 行)

**多轮工具调用流程**:

```
初始化消息 (用户输入 + 历史)
    ↓
for (round = 0; round < 10; round++)
    ├─ 发送给 LLM (with tools)
    │
    ├─ 处理 LLM 响应事件:
    │  ├─ LLMTextEvent → 流式输出文本
    │  ├─ LLMToolCallEvent → 工具调用
    │  └─ LLMDoneEvent → 本轮完成
    │
    ├─ 工具调用分类:
    │  ├─ UI Tools (action_confirmation, single_select, form etc.)
    │  │  → 触发 UI 回调，循环结束
    │  │
    │  ├─ get_tool_result → 查询工具执行历史
    │  │  → 继续下一轮
    │  │
    │  └─ 可执行工具 (skills, tool models, CLI commands)
    │     ├─ 检查权限 (enabled_cli_commands)
    │     ├─ 执行工具
    │     ├─ 保存到数据库
    │     └─ 返回结果给 LLM，继续下一轮
    │
    └─ 无工具调用 → 循环结束

生成最终响应消息
    ↓
保存到数据库
```

#### 📝 消息元数据 (metadata)

在 `_sendViaLocalLLM()` 方法中 (第 1152-1162 行):

```dart
final meta = <String, dynamic>{};
meta['trace_id'] = activeTask.taskId;           // 追踪 ID
if (messageMetadataExtra != null) meta.addAll(messageMetadataExtra!);
if (actionConfirmationData != null) meta['action_confirmation'] = actionConfirmationData;
if (singleSelectData != null) meta['single_select'] = singleSelectData;
if (multiSelectData != null) meta['multi_select'] = multiSelectData;
if (fileUploadData != null) meta['file_upload'] = fileUploadData;
if (formDataCapture != null) meta['form'] = formDataCapture;
```

---

## 3. Agent 数据模型

### 3.1 RemoteAgent 模型 (主要)

文件: `/lib/models/remote_agent.dart` (498 行)

#### 核心字段

```dart
class RemoteAgent {
  // 基本信息
  final String id;                        // UUID
  final String name;                      // 显示名称
  final String avatar;                    // emoji/URL
  final String? bio;                      // 描述
  
  // 连接配置
  final String token;                     // UUID token (认证)
  final String endpoint;                  // WebSocket/HTTP URL
  final ProtocolType protocol;            // ACP 或 custom
  final ConnectionType connectionType;    // WebSocket 或 HTTP
  
  // 状态
  final AgentStatus status;               // online/offline/error
  final int? lastHeartbeat;               // 毫秒时间戳
  final int? connectedAt;                 // 毫秒时间戳
  
  // 能力
  final List<String> capabilities;        // 能力列表
  final Map<String, dynamic> metadata;    // 元数据
  
  // 时间戳
  final int createdAt;                    // 创建时间
  final int updatedAt;                    // 更新时间
  final bool isPinned;                    // 是否置顶 (She 永远置顶)
}
```

#### 枚举类型

```dart
enum ProtocolType { acp, custom }
enum ConnectionType { websocket, http }
enum AgentStatus { online, offline, error }
```

#### 元数据字段 (metadata)

从 RemoteAgent 的各个 getter 方法可以看出存储的元数据:

| 字段名 | 类型 | 说明 | 示例 |
|--------|------|------|------|
| `llm_provider` | String | LLM 提供商 (sentinel for local agent) | "openai", "claude" |
| `main_model_id` | String | 主模型 ID (from ModelRegistry) | "gpt-4-vision", "claude-3-opus" |
| `llm_model` | String | 模型名称 (legacy, 优先使用 main_model_id) | "gpt-4" |
| `llm_api_base` | String | API 基础 URL (legacy) | "https://api.openai.com/v1" |
| `llm_api_key` | String | API 密钥 (legacy) | "sk-..." |
| `system_prompt` | String | 系统提示词 | 自定义系统提示 |
| `enabled_skills` | List<String> | 启用的技能列表 | ["skill1", "skill2"] |
| `enabled_tool_models` | List<String> | 启用的工具模型列表 | ["tool_model_1"] |
| `tool_model_scenarios` | Map | 工具模型场景覆盖 | {"tool_model_1": "场景描述"} |
| `enabled_cli_commands` | List<String> | 启用的 CLI 命令 (empty=允许全部) | ["os.file", "web.http"] |
| `enabled_os_tools` | List<String> | 启用的 OS 工具列表 | ["file", "network"] |
| `is_she` | bool | 是否为 She (内置守护 Agent) | true/false |
| `allow_external_access` | bool | 是否允许外部访问 | true/false |
| `channel_config` | Map | Channel 隧道配置 | {serverUrl, channelId, secret} |
| `target_agent_id` | String | 目标 Agent ID (外部访问时用) | "remote-agent-id" |
| `prompt_stack_config` | Map | 提示词栈配置 (She 专用功能开关) | 见下文 |
| `model_routing` | Map | 多模态模型路由 | 用于多模态能力 |

#### 快捷方法 (Getters)

```dart
// 能力检查
Set<String> get enabledOsTools
Set<String> get enabledSkills
Set<String> get enabledToolModels
Set<String> get enabledCliCommands
Map<String, String> get toolModelScenarios

// 状态检查
bool get isOnline => status == AgentStatus.online
bool get isShe
bool get allowExternalAccess
ChannelTunnelConfig? get channelConfig

// 模态支持 (多模态)
bool supportsModality(ModalityType modality)

// 显示文本
String get statusText, statusIcon, protocolName, connectionTypeName
```

### 3.2 Agent 模型 (旧)

文件: `/lib/models/agent.dart` (173 行)

较简单的数据模型，用于旧版 UI (AgentDetailScreen):

```dart
class Agent {
  final String id, name, avatar;
  final String? bio, type, description, model, systemPrompt;
  final double? temperature;
  final int? maxTokens;
  final List<String>? capabilities;
  final Map<String, dynamic>? metadata;
  final AgentProvider provider;
  final AgentStatus status;
}
```

---

## 4. Agent 编辑页面分析

### 4.1 RemoteAgentDetailScreen (主要)

文件: `/lib/screens/remote_agent_detail_screen.dart`

#### 编辑模式中的可配置项

| 项目 | 字段名 | 类型 | 备注 |
|------|--------|------|------|
| **基本信息** | | | |
| 名称 | `name` | String | 必填 |
| Bio | `bio` | String? | 可选 |
| 头像 | `avatar` | String (emoji/URL) | 可选上传本地图片 |
| **连接配置** | | | |
| 端点 | `endpoint` | String | 必填 (WebSocket/HTTP URL) |
| 协议 | `protocol` | ProtocolType | ACP / Custom |
| 连接类型 | `connectionType` | ConnectionType | WebSocket / HTTP |
| Token | `token` | String | 必填 (remote) / 可选 (local) |
| **LLM 配置** (仅本地 Agent) | | | |
| 主模型 | `main_model_id` | String? | 从 ModelRegistry 选择 |
| 系统提示词 | `system_prompt` | String? | 自定义提示词 |
| **工具和技能** (仅本地 Agent) | | | |
| 启用技能 | `enabled_skills` | Set<String> | 多选 |
| 工具模型 | `enabled_tool_models` | Set<String> | 带场景配置 |
| CLI 命令 | `enabled_cli_commands` | Set<String> | 权限控制 |
| **外部访问** (仅本地 Agent) | | | |
| 允许外部访问 | `allow_external_access` | bool | 开启后配置 Channel |
| Channel 服务器 URL | `channel_config.serverUrl` | String | |
| Channel ID | `channel_config.channelId` | String | |
| Channel Secret | `channel_config.secret` | String | |
| Channel 端点 | `channel_config.channelEndpoint` | String? | 可选 |
| **其他** | | | |
| Remote Agent ID | `target_agent_id` | String? | 连接到外部 Agent 时用 |

#### UI 布局结构

```
RemoteAgentDetailScreen
├─ 查看模式 (isEditing=false)
│  ├─ Agent 信息卡片 (头像、名称、状态)
│  ├─ 基本信息章节 (只读)
│  ├─ 连接配置章节 (只读)
│  ├─ LLM 配置章节 (仅本地 Agent, 只读)
│  ├─ 工具和技能章节 (仅本地 Agent, 只读)
│  ├─ 外部访问章节 (仅本地 Agent, 只读)
│  ├─ 操作按钮
│  │  ├─ 编辑按钮
│  │  ├─ 删除按钮
│  │  ├─ 重新生成 Token
│  │  └─ 开始对话
│  └─ 底部: 公网访问 URL (若配置了)
│
├─ 编辑模式 (isEditing=true)
│  ├─ 编辑表单 (TextFormField for each configurable item)
│  ├─ 模型选择器 (ModelSelectScreen)
│  ├─ 技能选择器 (SkillSelectScreen)
│  ├─ CLI 命令选择器 (CliCommandSelectScreen)
│  ├─ Channel 配置表单
│  └─ 按钮
│     ├─ 取消
│     └─ 保存
└─ 加载状态 (isLoading/isSaving)
```

#### 重要方法

1. `_initEditingControllers()` - 初始化编辑字段
2. `_enterEditMode()` / `_cancelEdit()` - 模式切换
3. `_saveEdit()` - 保存编辑 (包括验证、权限检查、DB 更新)
4. `_deleteAgent()` - 删除 Agent
5. `_regenerateToken()` - 重新生成 Token
6. `_showAvatarPicker()` - 头像选择

### 4.2 AddRemoteAgentScreen

文件: `/lib/screens/add_remote_agent_screen.dart`

#### 功能模式

两种创建模式:

| 模式 | `AgentCreationMode.create` | `AgentCreationMode.connect` |
|------|---------------------------|---------------------------|
| **场景** | 创建本地 Agent 配置 | 连接到远端 Agent |
| **需要的字段** | 名称、端点、头像、生物 | 名称、端点、Token、头像、生物 |
| **Token** | 自动生成 | 手动输入或自动解析 |
| **模型选择** | 可选 (本地 Agent) | 否 |
| **初始状态** | online (本地 Agent) | (等待连接) |

#### 自动 URL 解析功能

支持粘贴完整 URL 并自动分解:

```
输入: ws://host:port?token=xxx&agentId=yyy
分解后:
  endpoint: ws://host:port
  token: xxx
  target_agent_id: yyy
```

---

## 5. RemoteAgent 元数据配置体系

### 5.1 LLM 配置

**本地 Agent 识别**:
- 标记: `metadata['llm_provider'] != null`
- 默认状态: `online`

**模型配置** (优先级):
1. 首选: `main_model_id` + 在 ModelRegistry 查询
2. 备选: `llm_model` + `llm_api_base` + `llm_api_key` (旧版，已弃用)

### 5.2 工具和技能配置

#### 启用的工具/技能 (permission model)

1. **Enabled Skills**: 空 = 所有技能禁用，非空 = 只启用列表中的
2. **Enabled Tool Models**: 空 = 所有工具模型禁用，非空 = 只启用列表中的
3. **Enabled CLI Commands**: 空 = 所有 CLI 命令启用 (默认宽松), 非空 = 只启用列表中的

#### Tool Model Scenarios

支持为每个工具模型指定自定义场景:

```dart
metadata['tool_model_scenarios'] = {
  'tool_model_1': '自定义场景描述',
  'tool_model_2': '',  // 空字符串使用全局描述
};
```

### 5.3 She 特殊配置

```dart
metadata['is_she'] = true;  // 标记为 She

// 提示词栈配置 (She 专用)
metadata['prompt_stack_config'] = {
  'memory': true,
  'meditation': true,
  'tools': {'includeSkills': true, ...},
  // ... 其他 She 特定配置
};
```

### 5.4 外部访问配置

用于本地 Agent 对外暴露:

```dart
metadata['allow_external_access'] = true;

metadata['channel_config'] = {
  'serverUrl': 'https://channel.example.com',
  'channelId': 'my-channel-id',
  'secret': 'channel-secret',
  'channelEndpoint': null,  // 可选
  'autoConnect': false,
};
```

---

## 6. 关键流程

### 6.1 Agent 消息发送流程

```
用户发送消息
    ↓
sendMessageToAgent()
    ├─ 检查 Agent 是否为本地 LLM
    │  ├─ 是 → _sendViaLocalLLM()
    │  │  ├─ 多轮工具调用 (max 10 轮)
    │  │  └─ 返回最终消息
    │  │
    │  └─ 否 → 检查 Agent 是否在线
    │     ├─ 是 → 根据协议选择发送方式
    │     │  ├─ ACP → _sendViaACPProtocol() (timeout: 300s)
    │     │  └─ Other → _sendViaGenericProtocol()
    │     │
    │     └─ 否 → 返回错误
    │
    └─ 保存消息到数据库
        └─ 返回 agentResponse
```

### 6.2 工具调用权限检查

```
LLM 调用 CLI 命令
    ↓
检查 agent.enabledCliCommands
    ├─ 空 (默认) → 允许执行
    ├─ 非空 → 检查命令是否在列表中
    │  ├─ 是 → 执行
    │  └─ 否 → 返回拒绝错误
    │
    └─ 执行并保存结果
```

### 6.3 模型和能力支持检查

```
supportsModality(modality)
    ├─ 文本? → 总是支持
    ├─ 远端 ACP Agent? → 假设支持
    └─ 本地 Agent?
        ├─ Priority 1: 检查 enabled_tool_models 中是否有支持该模态的模型
        ├─ Priority 2: 检查 model_routing 中是否配置了该模态
        └─ Priority 3: 检查 LLM provider 是否有默认的视觉模型 (图像模态)
```

---

## 7. 数据库字段映射

RemoteAgent 在数据库中的存储:

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | TEXT PRIMARY KEY | UUID |
| `name` | TEXT | 显示名称 |
| `avatar` | TEXT | emoji/URL |
| `bio` | TEXT | 可选描述 |
| `token` | TEXT | 认证 Token |
| `endpoint` | TEXT | 连接端点 |
| `protocol` | TEXT | acp / custom |
| `connection_type` | TEXT | websocket / http |
| `status` | TEXT | online / offline / error |
| `last_heartbeat` | INTEGER | 毫秒时间戳 |
| `connected_at` | INTEGER | 毫秒时间戳 |
| `capabilities` | TEXT (JSON) | JSON 数组字符串 |
| `metadata` | TEXT (JSON) | JSON 对象字符串 |
| `created_at` | INTEGER | 创建时间戳 |
| `updated_at` | INTEGER | 更新时间戳 |
| `is_pinned` | INTEGER (0/1) | 是否置顶 |

---

## 8. 重要类和导入

```dart
// 数据模型
import '../models/remote_agent.dart';
import '../models/model_definition.dart';
import '../models/prompt_stack_config.dart';

// 服务
import '../services/remote_agent_service.dart';
import '../services/local_database_service.dart';
import '../services/model_registry.dart';
import '../services/skill_registry.dart';
import '../services/channel_tunnel_service.dart';

// UI 页面
import 'skill_select_screen.dart';
import 'model_select_screen.dart';
import 'cli_command_select_screen.dart';
```

---

## 9. 配置建议

### 9.1 可配置的参数 (考虑提供管理界面)

**消息服务参数**:
- [ ] `maxToolRounds`: 目前硬编码为 10，可改为配置
- [ ] `acp_task_timeout_seconds`: 目前硬编码为 300，可改为配置
- [ ] `chat_history_limit`: 目前硬编码为 20，可改为配置

**Agent 编辑表单参数**:
- [ ] 添加更多模态的支持选择
- [ ] 添加可配置的工具超时时间
- [ ] 添加工具调用日志级别配置

### 9.2 缺失的配置项

根据现有代码，以下项可以考虑添加:

1. **工具超时配置** - 每个工具或全局工具执行超时
2. **错误重试策略** - LLM 调用失败的重试次数和延迟
3. **流式输出配置** - 是否启用流式输出、缓冲大小等
4. **缓存配置** - 对话历史缓存策略

---

## 10. 代码片段参考

### 10.1 获取配置示例

```dart
final agent = await agentService.getAgent(agentId);

// 获取启用的技能
final skills = agent.enabledSkills;  // Set<String>

// 获取 LLM 配置
final modelId = agent.metadata['main_model_id'] as String?;
final modelDef = ModelRegistry.instance.getById(modelId);

// 检查外部访问
if (agent.allowExternalAccess) {
  final config = agent.channelConfig;
}

// 检查 She
if (agent.isShe) {
  final promptConfig = agent.promptStackConfig;
}
```

### 10.2 保存配置示例

```dart
final updatedAgent = agent.copyWith(
  name: newName,
  metadata: {
    ...agent.metadata,
    'enabled_skills': selectedSkills.toList(),
    'enabled_tool_models': selectedModels.keys.toList(),
    'tool_model_scenarios': scenarios,
    'system_prompt': customPrompt,
  },
);
await agentService.updateAgent(updatedAgent);
```

---

## 总结

Shepaw 的 Agent 配置系统采用了**灵活的元数据设计**:

✅ **优势**:
- 支持多种 Agent 类型 (远端 ACP、本地 LLM、She)
- 元数据存储灵活，易于扩展新功能
- 工具和技能的权限控制细粒度

⚠️ **需要关注的点**:
- 消息服务中有多个硬编码的常数，可考虑参数化
- 编辑表单随着功能增加变得复杂，可考虑分页/标签页设计
- 需要更详细的验证和错误提示


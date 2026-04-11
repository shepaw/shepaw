# Agent 配置系统可视化总结

## 🔍 RemoteAgent 数据结构

```
RemoteAgent (主数据模型)
│
├─ 📋 基本信息
│  ├─ id: String (UUID)
│  ├─ name: String
│  ├─ avatar: String (emoji/URL)
│  ├─ bio: String?
│  └─ isPinned: bool
│
├─ 🔌 连接配置
│  ├─ endpoint: String (WebSocket/HTTP URL)
│  ├─ protocol: ProtocolType (ACP/Custom)
│  ├─ connectionType: ConnectionType (WebSocket/HTTP)
│  └─ token: String (UUID认证令牌)
│
├─ 📊 状态信息
│  ├─ status: AgentStatus (online/offline/error)
│  ├─ lastHeartbeat: int? (ms timestamp)
│  └─ connectedAt: int? (ms timestamp)
│
├─ 🧠 能力
│  ├─ capabilities: List<String>
│  └─ metadata: Map<String, dynamic> ⭐ (关键部分)
│     │
│     ├─ 【LLM 配置】(本地 Agent 标记)
│     │  ├─ llm_provider: String ("openai"/"claude")
│     │  ├─ main_model_id: String (ModelRegistry ID)
│     │  ├─ llm_model: String? (旧版，已弃用)
│     │  ├─ llm_api_base: String? (旧版，已弃用)
│     │  └─ llm_api_key: String? (旧版，已弃用)
│     │
│     ├─ 【提示词配置】
│     │  ├─ system_prompt: String?
│     │  └─ prompt_stack_config: Map (She专用)
│     │     ├─ memory: bool
│     │     ├─ meditation: bool
│     │     └─ tools: Map (功能开关)
│     │
│     ├─ 【工具和技能配置】
│     │  ├─ enabled_skills: List<String>
│     │  ├─ enabled_tool_models: List<String>
│     │  ├─ tool_model_scenarios: Map<String, String>
│     │  ├─ enabled_cli_commands: List<String> (empty=全允许)
│     │  └─ enabled_os_tools: List<String>
│     │
│     ├─ 【外部访问配置】
│     │  ├─ allow_external_access: bool
│     │  ├─ channel_config: Map?
│     │  │  ├─ serverUrl: String
│     │  │  ├─ channelId: String
│     │  │  ├─ secret: String
│     │  │  └─ channelEndpoint: String?
│     │  └─ target_agent_id: String?
│     │
│     ├─ 【特殊标记】
│     │  ├─ is_she: bool
│     │  └─ model_routing: Map (多模态)
│     │
│     └─ 【其他】
│        └─ ... (可扩展)
│
└─ ⏰ 时间戳
   ├─ createdAt: int (ms)
   └─ updatedAt: int (ms)
```

---

## 🎯 Agent 编辑页面配置项映射

### RemoteAgentDetailScreen 编辑表单

```
【编辑模式】 _isEditing=true
│
├─ 【基本信息】━━━━━━━━━━━━━━━━━━━━━━━━━━━━
│  ├─ TextFormField ─→ _nameController ─→ agent.name
│  ├─ TextFormField ─→ _bioController ─→ agent.bio
│  ├─ AvatarPicker ─→ _editingAvatar ─→ agent.avatar
│  └─ Icon (只读) ──→ agent.id
│
├─ 【连接配置】━━━━━━━━━━━━━━━━━━━━━━━━━━━━
│  ├─ TextFormField ─→ _endpointController ─→ agent.endpoint
│  ├─ DropdownButton ─→ _editingProtocol ─→ agent.protocol
│  ├─ DropdownButton ─→ _editingConnectionType ─→ agent.connectionType
│  └─ TextFormField ─→ _tokenController ─→ agent.token
│
├─ 【LLM 配置】(条件显示: _isLocalMode) ═════
│  ├─ ModelSelectScreen ─→ _selectedMainModelId
│  │  └─ metadata['main_model_id']
│  │  └─ metadata['llm_provider']
│  │
│  └─ TextFormField ─→ _systemPromptController
│     └─ metadata['system_prompt']
│
├─ 【工具和技能】(条件显示: _isLocalMode) ═══
│  ├─ SkillSelectScreen ─→ _enabledSkills
│  │  └─ metadata['enabled_skills']
│  │
│  ├─ ToolModelSelectScreen ─→ _toolModelScenarios
│  │  ├─ metadata['enabled_tool_models']
│  │  └─ metadata['tool_model_scenarios']
│  │
│  └─ CliCommandSelectScreen ─→ _enabledCliCommands
│     └─ metadata['enabled_cli_commands']
│
├─ 【外部访问】(条件显示: _isLocalMode) ════
│  ├─ SwitchButton ─→ _editingAllowExternalAccess
│  │  └─ metadata['allow_external_access']
│  │
│  └─ [IF allow_external_access=true]
│     ├─ TextFormField ─→ _channelServerUrlController
│     │  └─ metadata['channel_config']['serverUrl']
│     ├─ TextFormField ─→ _channelIdController
│     │  └─ metadata['channel_config']['channelId']
│     ├─ TextFormField ─→ _channelSecretController
│     │  └─ metadata['channel_config']['secret']
│     └─ TextFormField ─→ _channelEndpointController
│        └─ metadata['channel_config']['channelEndpoint']
│
├─ 【其他】━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
│  └─ TextFormField ─→ _remoteAgentIdController
│     └─ metadata['target_agent_id']
│
└─ 【操作按钮】
   ├─ [取消] → _cancelEdit()
   └─ [保存] → _saveEdit() → agentService.updateAgent()

【查看模式】 _isEditing=false
│
├─ [编辑按钮] ──→ _enterEditMode()
├─ [删除按钮] ──→ _deleteAgent()
├─ [重新生成Token] ──→ _regenerateToken()
├─ [开始对话] ──→ _startConversation()
└─ 显示模式下的所有字段为只读
```

---

## 🔄 Agent 消息服务执行流程

```
┌─────────────────────────────────────────────────────────────┐
│ User sends message to Agent                                 │
└────────────────┬────────────────────────────────────────────┘
                 │
         ┌───────▼──────────┐
         │ sendMessageToAgent│
         └───────┬──────────┘
                 │
    ┌────────────▼────────────────┐
    │ Is Local LLM Agent?         │
    │ (metadata['llm_provider']!= null)
    │                             │
    ├──────[YES]─────────┬────────[NO]────────┐
    │                    │                    │
    │          ┌─────────▼────────┐    ┌──────▼─────────┐
    │          │Local LLM Path    │    │Is Agent Online?│
    │          │_sendViaLocalLLM()│    │                │
    │          └─────────┬────────┘    ├─[YES]────┬─────[NO]─────┐
    │                    │             │          │              │
    │    ┌───────────────▼──────────┐  │   ┌──────▼────┐  ┌──────▼──────┐
    │    │ Multi-Round Tool Calling │  │   │Is Protocol│  │Return Error │
    │    │ Loop (max 10 rounds)     │  │   │ACP?       │  │             │
    │    │                          │  │   ├─[YES]─┬───[NO]─┐         │
    │    │ for (round 0 to 10):     │  │   │       │        │         │
    │    │ 1. Chat with LLM         │  │   │   ┌───▼────┐ ┌─▼───────┐ │
    │    │ 2. Parse response:       │  │   │   │_sendVia│ │_sendVia │ │
    │    │    - LLMTextEvent        │  │   │   │ACPProto│ │Generic  │ │
    │    │    - LLMToolCallEvent    │  │   │   │col()   │ │Protocol()│ │
    │    │    - LLMDoneEvent        │  │   │   │        │ │         │ │
    │    │                          │  │   │   │⏱️300sec│ │         │ │
    │    │ 3. Route tool calls:     │  │   │   │timeout │ │         │ │
    │    │    ├─ UI Tools           │  │   │   └────────┘ └─────────┘ │
    │    │    │  → Fire and End     │  │   │       │            │    │
    │    │    │                     │  │   │       └─────┬──────┘    │
    │    │    ├─ get_tool_result    │  │   │            │           │
    │    │    │  → Fetch & Continue │  │   │            ▼           │
    │    │    │                     │  │   │    (Agent Response)     │
    │    │    └─ Executable Tools   │  │   │            │           │
    │    │       (Skills/CLI/Models)│  │   │            │           │
    │    │       → Execute          │  │   │            │           │
    │    │       → Save to DB       │  │   │            │           │
    │    │       → Continue         │  │   │            │           │
    │    │                          │  │   │            │           │
    │    │ 4. No tool calls → Exit  │  │   │            │           │
    │    │                          │  │   │            │           │
    │    └──────────┬───────────────┘  │   │            │           │
    │               │                   │   │            │           │
    │         ┌─────▼────────┐         │   │            │           │
    │         │Generate Final │        │   │            │           │
    │         │Response       │        │   │            │           │
    │         │Message        │        │   │            │           │
    │         └─────┬────────┘         │   │            │           │
    │               │                   │   │            │           │
    │               └───────────┬───────┴───┴────────────┘           │
    │                           │                                    │
    │           ┌───────────────▼─────────────────┐                 │
    │           │ Save message to database        │                 │
    │           │ (DB save completed callback)    │                 │
    │           └───────────────┬─────────────────┘                 │
    │                           │                                   │
    │           ┌───────────────▼──────────────────┐                │
    │           │ Return agentResponse             │                │
    │           │ (back to UI)                     │                │
    │           └───────────────────────────────────┘                │
    │                                                                 │
    └─────────────────────────────────────────────────────────────┘
```

---

## 🔐 权限检查流程 (CLI Commands)

```
┌──────────────────────────────────────────────┐
│ LLM invokes CLI tool                         │
│ tool_name: String                            │
│ arguments: Map                               │
└──────────────────┬───────────────────────────┘
                   │
        ┌──────────▼──────────┐
        │ Extract namespace   │
        │ namespace = arg     │
        │ subcommand = arg    │
        │ commandId = ns.sub  │
        └──────────┬──────────┘
                   │
        ┌──────────▼──────────────────┐
        │ Check enabledCliCommands    │
        │ agent.enabledCliCommands    │
        └──────────┬──────────────────┘
                   │
        ┌──────────▼────────────┐
        │ Is it empty (default)?│
        │                       │
        ├──[YES: 默认允许]──┬───[NO: 严格模式]──┐
        │                 │                  │
        │           ┌─────▼────┐       ┌─────▼────────┐
        │           │Execute    │       │commandId in  │
        │           │Tool       │       │enabledList?  │
        │           │           │       │              │
        │           └─────┬────┘       ├─[YES]──┬─────[NO]─┐
        │                 │            │        │          │
        │           ┌─────▼──────┐    ┌─▼────┐ ┌─▼────────┐│
        │           │Save Result │    │Exec. │ │Return    ││
        │           │To DB       │    │Tool  │ │Deny Error││
        │           │            │    │      │ │          ││
        │           └─────┬──────┘    └──┬───┘ └──────┬───┘│
        │                 │              │            │   │
        │                 └──────────┬───┴────────────┘   │
        │                            │                    │
        │               ┌────────────▼──────────┐         │
        │               │ Return tool result    │         │
        │               │ to LLM for next round │         │
        │               └───────────────────────┘         │
        │                                                 │
        └─────────────────────────────────────────────────┘
```

---

## 📦 数据库操作流程

```
【创建 Agent】 AddRemoteAgentScreen._createAgent()
│
├─ 构建 metadata
├─ 调用 RemoteAgentService.createAgent()
├─ 保存到数据库 (SQLite)
└─ 返回成功消息

【编辑 Agent】 RemoteAgentDetailScreen._saveEdit()
│
├─ 验证必填字段
├─ 收集所有编辑字段值
├─ 构建更新后的 metadata
│  ├─ llm_provider, main_model_id
│  ├─ enabled_skills, enabled_tool_models
│  ├─ tool_model_scenarios, enabled_cli_commands
│  ├─ system_prompt, channel_config
│  └─ 其他字段...
├─ 创建新的 RemoteAgent 实例 (copyWith)
├─ 调用 RemoteAgentService.updateAgent()
├─ 数据库更新
└─ 刷新公网 URL 配置

【删除 Agent】 RemoteAgentDetailScreen._deleteAgent()
│
├─ 显示确认对话
├─ 调用 RemoteAgentService.deleteAgent(id)
├─ 数据库删除
└─ 返回导航

【重新生成 Token】 RemoteAgentDetailScreen._regenerateToken()
│
├─ 确认操作
├─ 调用 TokenService.generateNewToken()
├─ 更新数据库中的 token 字段
└─ 本地更新 agent.token
```

---

## 🎨 UI 组件关系图

```
主导航
 │
 ├─ 📱 ChatScreen
 │   └─ Agent Icon → RemoteAgentDetailScreen
 │
 ├─ 🔧 RemoteAgentListScreen
 │   ├─ [+ 添加] ──→ AddRemoteAgentScreen
 │   │   ├─ ModelSelectScreen
 │   │   ├─ SkillSelectScreen
 │   │   └─ [ModelRegistry选择]
 │   │
 │   └─ Agent List Item → RemoteAgentDetailScreen
 │
 └─ RemoteAgentDetailScreen
     ├─ [编辑] 进入编辑模式
     │   ├─ ModelSelectScreen ────────┐
     │   ├─ SkillSelectScreen ────────┤
     │   ├─ CliCommandSelectScreen ───┤─→ 编辑表单
     │   └─ ChannelConfigSection ────┘
     │
     ├─ [删除] 删除确认对话
     ├─ [重新生成Token] 验证对话
     ├─ [开始对话] 跳转到 ChatScreen
     │
     └─ 只读显示所有配置项
```

---

## 🔑 关键常数回顾

| 常数 | 值 | 位置 | 影响 |
|------|-----|------|------|
| `maxToolRounds` | 10 | agent_messaging_service.dart:840 | 本地LLM多轮工具调用最大轮数 |
| `ACP timeout` | 300s | agent_messaging_service.dart:476-480 | ACP远端Agent任务超时 |
| `historyLimit` | 20 | agent_messaging_service.dart:751,1258 | 加载的聊天历史条数 |

---

## ✅ 检查清单：配置完整性

```
创建/编辑 Agent 时应配置:

基本信息:
  ✓ name (必填)
  ✓ bio (可选)
  ✓ avatar (可选)

连接配置:
  ✓ endpoint (必填)
  ✓ protocol (ACP/Custom)
  ✓ connectionType (WebSocket/HTTP)
  ✓ token (必填for remote / 可选for local)

本地Agent特有:
  ✓ llm_provider + main_model_id
  ✓ system_prompt (可选)
  ✓ enabled_skills (可选)
  ✓ enabled_tool_models + scenarios (可选)
  ✓ enabled_cli_commands (可选)

外部访问(可选):
  ✓ allow_external_access (bool)
  ✓ channel_config (if enabled)
    ├─ serverUrl (必填)
    ├─ channelId (必填)
    ├─ secret (必填)
    └─ channelEndpoint (可选)

特殊配置:
  ✓ target_agent_id (用于连接外部Agent)
  ✓ is_she (标记为She)
  ✓ prompt_stack_config (She专用)
```


# ShePaw 代码架构可视化

## 1. 文件结构概览

```
lib/
├── screens/                          # 主要页面
│   ├── chat_screen.dart             # ⭐ Chat 主界面 (DM + Group)
│   ├── agent_list_screen.dart       # ⭐ Agent 列表 (本地)
│   ├── agent_detail_screen.dart     # ⭐ Agent 详情/编辑
│   ├── remote_agent_list_screen.dart    # Remote Agent 列表
│   ├── remote_agent_detail_screen.dart  # Remote Agent 详情/编辑
│   ├── group_detail_screen.dart     # ⭐ 群组详情/编辑
│   ├── channel_list_screen.dart     # 频道列表
│   └── ...
├── widgets/
│   ├── chat/                        # ⭐ Chat 相关组件
│   │   ├── chat_menu.dart          # 菜单逻辑 (Agent + Group)
│   │   ├── chat_app_bar.dart       # AppBar
│   │   ├── session_list_panel.dart # DM 会话列表
│   │   ├── group_session_list_panel.dart # Group 会话列表
│   │   ├── chat_input_area.dart
│   │   ├── chat_message_list.dart
│   │   └── ...
│   └── ...
├── models/
│   ├── agent.dart                   # Agent 数据模型
│   ├── remote_agent.dart            # Remote Agent 数据模型
│   ├── channel.dart                 # 频道/群组数据模型
│   └── ...
└── services/
    ├── local_api_service.dart       # 本地 Agent API
    ├── local_database_service.dart  # 数据库操作
    └── ...
```

---

## 2. 菜单系统架构

```
ChatScreen (右上角 Icons.more_vert)
│
├─→ DM 模式 (Agent 1对1)
│   │
│   └─→ ChatMenuHelper.showAgentMenu()
│       ├─ "重置会话" → _sendMessage('/reset')
│       ├─ "查看详情" → _navigateToAgentDetail()
│       │              → RemoteAgentDetailScreen
│       ├─ "自定义系统提示" → _showDmSystemPromptDialog()
│       └─ "搜索消息" → _showSearchDialog()
│
└─→ Group 模式 (群组)
    │
    └─→ ChatMenuHelper.showGroupMenu()
        ├─ "编辑群组信息" → _editGroupInfo()
        │                   → GroupDetailScreen(startInEditMode=true)
        ├─ "查看群组成员" → _showGroupMembersPanel()
        ├─ "添加群组成员" → _addGroupMember()
        └─ "搜索消息" → _showSearchDialog()


AgentListScreen (列表项右侧 Icons.more_vert)
│
└─→ PopupMenuButton
    ├─ "发起对话" → _startConversation()
    │              → 创建 DM Channel
    │              → ChatScreen
    ├─ "查看详情" → _navigateToAgentDetail()
    │              → AgentDetailScreen
    └─ "删除" → _deleteAgent()


RemoteAgentListScreen (列表项右侧 Icons.more_vert)
│
└─→ PopupMenuButton
    ├─ "查看 Token" → AgentTokenDisplayScreen
    └─ "删除" → _deleteAgent()
```

---

## 3. 编辑功能流程

### 3.1 Agent 编辑流程

```
AgentListScreen
    │
    ├─ "查看详情" 按钮
    │   ↓
    └─→ AgentDetailScreen (agent=某个Agent)
            │
            ├─ 查看模式 (_isEditing = false)
            │   ├─ 右上角: Edit 按钮 (Icons.edit)
            │   ├─ 所有字段: disabled
            │   └─ "发起对话" 按钮
            │       ↓
            │       (创建 DM Channel)
            │       ↓
            │       ChatScreen
            │
            └─ 编辑模式 (_isEditing = true)
                ├─ 右上角: Edit 按钮消失
                ├─ 所有字段: enabled
                │   ├ Agent 名称
                │   ├ Agent 类型
                │   ├ Agent 状态 (Dropdown)
                │   └ Avatar URL
                └─ 操作按钮
                    ├─ "取消" → 恢复原值 → 查看模式
                    └─ "保存" → _saveAgent()
                           → await _apiService.updateAgent()
                           → 查看模式 (_isEditing = false)
                           → 返回 AgentListScreen
                           → _loadAgents() (刷新)
```

### 3.2 远端 Agent 编辑流程

```
RemoteAgentListScreen
    │
    ├─ 卡片点击 或 "查看 Token" 菜单项
    │   ↓
    └─→ AgentTokenDisplayScreen (显示连接 Token 和详情)
            │
            └─→ RemoteAgentDetailScreen (agent: RemoteAgent)
                    │
                    ├─ 查看模式 (_isEditing = false)
                    │   ├─ 所有字段: disabled
                    │   └─ 详情信息显示
                    │
                    └─ 编辑模式 (_isEditing = true)
                        ├─ 基础配置
                        │   ├─ Name
                        │   ├─ Bio
                        │   ├─ Endpoint
                        │   ├─ Token
                        │   ├─ Protocol
                        │   └─ Connection Type
                        ├─ 高级配置
                        │   ├─ Skills 管理
                        │   ├─ Tool Models 管理
                        │   ├─ CLI Commands 管理
                        │   ├─ System Prompt
                        │   └─ LLM Model 配置
                        └─ 外部访问配置
                            ├─ Allow External Access
                            └─ Channel Configuration
```

### 3.3 群组编辑流程

```
ChatScreen (Group 模式)
    │
    └─ 右上角菜单 → "编辑群组信息"
        ↓
        └─→ GroupDetailScreen(startInEditMode=true)
                │
                ├─ 编辑模式 (_isEditing = true) [自动]
                │   ├─ 编辑字段:
                │   │   ├─ 群组名称
                │   │   ├─ 描述
                │   │   ├─ 系统提示
                │   │   ├─ 提及模式 (Mention Mode)
                │   │   ├─ Planning Mode
                │   │   └─ Flow Mode
                │   └─ 操作按钮
                │       ├─ "保存" → _saveEdit()
                │       │         → await _databaseService.updateChannel()
                │       │         → Navigator.pop(context, updated)
                │       │         → ChatScreen (自动更新)
                │       └─ "取消" → 直接返回
                │
                └─ 查看模式 (_isEditing = false) [从 GroupDetailScreen 打开]
                    ├─ 显示群组详情
                    ├─ "编辑" 按钮 (右上角) → 进入编辑模式
                    ├─ "删除群组" 按钮
                    └─ 成员列表等信息
```

---

## 4. 代码层级结构

### 4.1 界面层 (Screens)

```
Tier 1: 列表界面
├─ AgentListScreen         - 本地 Agent 列表
├─ RemoteAgentListScreen   - 远端 Agent 列表
├─ ChannelListScreen       - 频道/群组列表
└─ ChatScreen             - Chat 主界面 (Tier 2 容器)

Tier 2: 详情/编辑界面
├─ AgentDetailScreen          - Agent 详情/编辑/创建
├─ RemoteAgentDetailScreen    - Remote Agent 详情/编辑
├─ GroupDetailScreen          - 群组详情/编辑
├─ AgentTokenDisplayScreen    - 显示 Remote Agent Token
└─ RemoteAgentDetailScreen    - 远端 Agent 全部配置

Tier 3: 辅助界面
├─ ModelSelectScreen       - 模型选择
├─ SkillSelectScreen       - 技能选择
├─ CliCommandSelectScreen  - CLI 命令选择
└─ ...
```

### 4.2 组件层 (Widgets)

```
ChatScreen 内部组件树:
ChatScreen
├─ AppBar
│   ├─ ChatDMAppBarTitle (DM 模式)
│   │   ├─ Agent 名称
│   │   ├─ 在线状态
│   │   └─ 停止按钮
│   ├─ ChatGroupAppBarTitle (Group 模式)
│   │   ├─ 群组名称
│   │   └─ 成员数
│   └─ Actions
│       ├─ IconButton (History/Sessions) → SessionListPanel
│       └─ IconButton (Menu) → ChatMenuHelper.showXxxMenu()
│
├─ Body
│   ├─ SheConfigBanner (She 需要配置时)
│   ├─ ChatMessageList
│   │   └─ Messages 列表
│   ├─ ScrollToBottom Button (用户上滑时)
│   └─ VoiceRecordOverlay (录音中)
│
└─ BottomSheet/Panels
    ├─ SessionListPanel (DM 会话)
    ├─ GroupSessionListPanel (Group 会话)
    ├─ ChatInputArea (输入框)
    │   ├─ TextFormField
    │   ├─ 附件按钮
    │   ├─ 表情选择器
    │   ├─ 语音录制
    │   └─ 发送按钮
    └─ EmojiPicker
```

### 4.3 数据层 (Models & Services)

```
数据模型:
├─ Agent
│   ├─ id, name, type
│   ├─ avatar, provider
│   └─ status (online/offline/busy)
│
├─ RemoteAgent
│   ├─ 基础字段 (name, bio, endpoint, token)
│   ├─ Skills, ToolModels, CliCommands
│   ├─ 连接配置 (protocol, connectionType)
│   └─ 外部访问配置
│
├─ Channel
│   ├─ id, name, type (dm/group)
│   ├─ members[], isDM, isPrivate
│   ├─ systemPrompt, description
│   ├─ mentionMode, planningMode, flowMode
│   └─ avatar, createdAt, createdBy
│
└─ Message
    ├─ id, channelId, senderId
    ├─ content, type (text/image/file/form)
    ├─ timestamp
    └─ ...

API 服务:
├─ LocalApiService
│   ├─ registerAgent() - 创建 Agent
│   ├─ updateAgent() - 编辑 Agent
│   ├─ deleteAgent() - 删除 Agent
│   ├─ getAgents() - 获取 Agent 列表
│   ├─ getChannels() - 获取频道
│   └─ createChannel() - 创建 DM
│
└─ LocalDatabaseService
    ├─ updateChannel() - 更新频道/群组
    ├─ getLatestChannelMessage() - 获取最新消息
    └─ ...
```

---

## 5. 快速导航地图

```
🎯 "我要编辑 Agent"
   ↓
   Step 1: 打开 AgentListScreen (或从 ChatScreen 点"查看详情")
   Step 2: 点列表项右侧 "⋯" 菜单 → "查看详情"
       或 直接点列表项 → 进入 AgentDetailScreen
   Step 3: 点右上角 Edit 按钮 → 进入编辑模式 (_isEditing = true)
   Step 4: 修改字段内容
   Step 5: 点"保存"按钮 → updateAgent() API 调用
   Step 6: 返回 AgentListScreen 并刷新列表
   
   📍 关键文件:
   - lib/screens/agent_detail_screen.dart (123-128: Edit 按钮)
   - lib/screens/agent_detail_screen.dart (41-108: _saveAgent 方法)


🎯 "我要编辑群组"
   ↓
   Step 1: 在 ChatScreen (Group 模式) 点右上角 "⋯" 菜单
   Step 2: 选择 "编辑群组信息"
   Step 3: 进入 GroupDetailScreen(startInEditMode=true)
   Step 4: 自动进入编辑模式，修改群组信息
   Step 5: 点"保存"按钮 → updateChannel() API 调用
   Step 6: 返回 ChatScreen，群组信息自动更新
   
   📍 关键文件:
   - lib/screens/chat_screen.dart (1342-1348: 编辑群组菜单)
   - lib/screens/group_detail_screen.dart (88-96: 编辑模式逻辑)


🎯 "我要看 Agent 列表菜单"
   ↓
   📍 文件位置:
   - lib/screens/agent_list_screen.dart (278-325)
   
   菜单项:
   ✓ "发起对话" (Icons.chat)
   ✓ "查看详情" (Icons.info_outline)
   ✓ "删除" (Icons.delete_outline)


🎯 "我要看 Chat 菜单"
   ↓
   📍 文件位置:
   - lib/widgets/chat/chat_menu.dart (完整菜单定义)
   - lib/screens/chat_screen.dart (1338-1362: 菜单触发)
   
   两种模式菜单定义:
   - showAgentMenu() - DM 1对1 菜单 (11-53 行)
   - showGroupMenu() - Group 群组菜单 (56-97 行)
```

---

## 6. 状态管理概览

### 6.1 编辑页面状态

```
AgentDetailScreen:
├─ _isEditing: bool          # 编辑模式开关
├─ _isLoading: bool          # 加载状态
├─ _nameController: TextEditingController
├─ _typeController: TextEditingController
├─ _avatarController: TextEditingController
└─ _selectedStatus: String   # Agent 状态

GroupDetailScreen:
├─ _isEditing: bool
├─ _isSaving: bool
├─ _nameController
├─ _descController
├─ _systemPromptController
├─ _selectedMentionMode: String
├─ _planningMode: bool
└─ _flowMode: bool

RemoteAgentDetailScreen:
├─ _isEditing: bool
├─ _isSaving: bool
├─ _isRegeneratingToken: bool
├─ [多个编辑控制器]
├─ _enabledSkills: Set<String>
├─ _enabledCliCommands: Set<String>
└─ ...
```

### 6.2 列表页面状态

```
AgentListScreen:
├─ _agents: List<Agent>
├─ _isLoading: bool
└─ _errorMessage: String?

RemoteAgentListScreen:
├─ _agents: List<RemoteAgent>
├─ _isLoading: bool
└─ [无错误消息字段]
```

---

## 7. API 调用流程

### 7.1 编辑 Agent 的 API 调用

```
界面: AgentDetailScreen
   ↓
用户点"保存"
   ↓
_saveAgent() 方法
   ↓
if (widget.agent == null)
   → registerAgent() - 创建新 Agent
else
   → updateAgent() - 编辑现有 Agent
   ↓
成功响应
   ↓
setState(() => _isEditing = false)
   ↓
showSnackBar: "Agent 更新成功"
```

### 7.2 编辑群组的 API 调用

```
界面: GroupDetailScreen (编辑模式)
   ↓
用户点"保存"
   ↓
_saveEdit() 方法
   ↓
_databaseService.updateChannel(updated)
   ↓
成功响应
   ↓
if (widget.startInEditMode)
   → Navigator.pop(context, updated)  # 返回到 ChatScreen
else
   → setState(() => _isEditing = false)  # 在当前页切换到查看模式
```

---

## 8. 事件流总结

```
用户交互流:
┌─────────────────┬──────────────────┬──────────────────┐
│  代理/群组列表   │   Chat 界面       │   详情/编辑页面   │
├─────────────────┼──────────────────┼──────────────────┤
│                 │                  │                  │
│ 点"查看详情"    │ 点"查看详情"     │                  │
│       ↓         │       ↓          │                  │
│ → AgentDetail   │ → AgentDetail    │                  │
│   (查看)        │   (查看)         │                  │
│                 │                  │                  │
│                 │ 点菜单→编辑群组   │                  │
│                 │       ↓          │                  │
│                 │ → GroupDetail    │                  │
│                 │   (编辑模式)     │                  │
│                 │                  │                  │
│                 │                  │ 点"Edit"按钮     │
│                 │                  │      ↓           │
│                 │                  │ 进入编辑模式     │
│                 │                  │      ↓           │
│                 │                  │ 修改数据并保存   │
│                 │                  │      ↓           │
│                 │                  │ API 调用        │
│                 │                  │      ↓           │
│                 │                  │ 返回上级页面     │
│                 │                  │      ↓           │
│                 │                  │ 刷新列表/UI 更新 │
└─────────────────┴──────────────────┴──────────────────┘
```


# ShePaw: Essential Files to Read (In Order)

## 🚀 Start Here (5-10 minutes)
1. **lib/main.dart** - App entry point, service initialization
2. **README.md** - Project overview and features
3. **QUICK_START_GUIDE.md** - Developer quick reference

## 📊 Understanding the Architecture (20-30 minutes)
1. **ARCHITECTURE_DIAGRAM.txt** - Visual system architecture
2. **SHEPAW_EXPLORATION.md** - Comprehensive technical overview
3. **lib/models/message.dart** - Core message model
4. **lib/models/remote_agent.dart** - Agent definition and types

## 💬 Message Flow & Chat System (30-45 minutes)
1. **lib/services/chat_service.dart** (45KB) - Central message hub
   - Core: `sendMessage()`, `loadChannelMessages()`, `watchMessages()`
   - Understanding stream management and routing

2. **lib/screens/chat_screen.dart** (84KB) - Main chat UI
   - How messages are displayed
   - Real-time updates using StreamBuilder

3. **lib/widgets/chat/chat_input_area.dart** (41KB) - User input
   - Message composition and file attachment

4. **lib/widgets/message_bubble.dart** (22KB) - Message rendering
   - Base rendering for text, images, files, audio

## 🤖 Agent Communication (30-40 minutes)
1. **lib/services/local_llm_agent_service.dart** (56KB)
   - Local LLM integration (OpenAI, Claude, etc)
   - Streaming response handling
   - Provider compatibility layer

2. **lib/services/acp_agent_connection.dart** (20KB)
   - Remote agent connection (WebSocket, JSON-RPC 2.0)
   - Bidirectional communication protocol
   - Connection pooling

3. **lib/services/remote_agent_service.dart** (18KB)
   - Agent lifecycle management
   - Token authentication

4. **lib/models/acp_protocol.dart** - ACP protocol definitions
   - JSON-RPC 2.0 structure
   - Request/response formats

## 💾 Data Persistence (15-20 minutes)
1. **lib/services/local_database_service.dart** (49KB) - Database wrapper
   - SQLite table definitions
   - CRUD operations
   - Schema design

2. **lib/models/channel.dart** - Conversation model
3. **lib/models/agent.dart** - Agent model
4. **pubspec.yaml** - Dependencies (sqflite, hive, shared_preferences)

## 🛠️ Configuration & Extensions (25-35 minutes)
1. **lib/services/skill_registry.dart** - Markdown skills
   - How to add custom skills
   - SKILL.md format

2. **lib/services/model_registry.dart** - Tool models
   - Custom tool definitions
   - SharedPreferences storage

3. **lib/services/cli_tool_registry.dart** - External CLI tools
   - cli-tool.json manifest format
   - JSON stdio protocol

4. **lib/clis/shepaw/os/os_tool_registry.dart** - Built-in OS tools
   - Shell commands, file I/O, processes
   - Risk levels and platform filtering

5. **lib/services/ui_component_registry.dart** - UI components
   - Forms, buttons, confirmations
   - LLM tool definitions

## 👥 Group Orchestration (25-40 minutes)
1. **lib/services/group/group_orchestration_service.dart** (82KB)
   - Multi-agent coordination
   - Three modes: Standard, Planning, Flow

2. **lib/services/group/group_agent_executor.dart** (39KB)
   - Per-agent execution

3. **lib/services/group/planning_helpers.dart**
   - Planning mode task board

4. **lib/services/flow_executor.dart** (20KB)
   - Workflow execution with pause/resume/skip

## 🎨 UI Components (15-25 minutes)
1. **lib/screens/add_remote_agent_screen.dart** (48KB) - Agent setup wizard
2. **lib/screens/cli_config_management_screen.dart** (150KB) - Tool configuration
3. **lib/widgets/form_bubble.dart** (22KB) - Interactive forms
4. **lib/widgets/plan_approval_card.dart** (12KB) - Planning mode UI
5. **lib/widgets/task_board_widget.dart** (14KB) - Task board UI

## 🔐 Security & Auth (10-15 minutes)
1. **lib/services/password_service.dart** - Password hashing/verification
2. **lib/services/secure_key_manager.dart** - Encrypted key management
3. **lib/services/permission_service.dart** - Permission system
4. **lib/widgets/os_tool_confirmation_dialog.dart** - Permission dialogs

## 📱 Platform-Specific (10-15 minutes)
1. **lib/sub_window_app.dart** - Desktop multi-window support
2. **lib/screens/desktop_home_screen.dart** (40KB) - Desktop layout
3. **lib/screens/home_screen.dart** (48KB) - Mobile layout
4. **lib/utils/layout_utils.dart** - Responsive layout logic

## ⚙️ Configuration (5-10 minutes)
1. **lib/config/env_config.dart** - Environment variables
2. **lib/config/app_config.dart** - App configuration
3. **pubspec.yaml** - Dependency versions and build config

## 📝 Other Important Files
1. **lib/providers/app_state.dart** - Global state management
2. **lib/services/logger_service.dart** - Logging system
3. **lib/services/inference_log_service.dart** - Token usage tracking
4. **lib/services/trace_service.dart** - Request tracing

---

## File Size Reference (Largest Files)
1. cli_config_management_screen.dart - 150KB ⚠️ Complex!
2. chat_screen.dart - 84KB
3. group_orchestration_service.dart - 82KB
4. add_remote_agent_screen.dart - 48KB
5. home_screen.dart - 48KB
6. local_llm_agent_service.dart - 56KB
7. local_database_service.dart - 49KB
8. desktop_home_screen.dart - 40KB
9. group_agent_executor.dart - 39KB
10. chat_service.dart - 45KB

---

## Reading Paths by Use Case

### 🎯 I want to understand message flow
1. chat_service.dart
2. chat_screen.dart
3. local_llm_agent_service.dart
4. message_bubble.dart

### 🤖 I want to add a new LLM provider
1. local_llm_agent_service.dart (key file)
2. remote_agent.dart
3. models/llm_provider_config.dart
4. add_remote_agent_screen.dart

### 👥 I want to add multi-agent features
1. group_orchestration_service.dart
2. group_agent_executor.dart
3. planning_helpers.dart
4. flow_executor.dart

### 🛠️ I want to add new tools/skills
1. skill_registry.dart
2. os_tool_registry.dart
3. cli_tool_registry.dart
4. model_registry.dart

### 🔧 I want to modify configuration
1. env_config.dart
2. app_config.dart
3. tool_config_service.dart
4. permission_service.dart

### 🎨 I want to create new UI components
1. message_bubble.dart
2. chat_input_area.dart
3. form_bubble.dart
4. ui_component_registry.dart

---

## Documentation Files
- **SHEPAW_EXPLORATION.md** - Complete technical reference
- **ARCHITECTURE_DIAGRAM.txt** - Visual system design
- **QUICK_START_GUIDE.md** - Developer quick reference (this file)
- **BUILD_GUIDE.md** - Platform build instructions
- **DEVELOPMENT.md** - Code style and workflow
- **docs/agent_integration_guide.md** - ACP protocol documentation
- **docs/remote_llm_agent_integration_en.md** - Third-party agent setup
- **docs/USER_GUIDE_EN.md** - End-user manual
- **README.md** - Project overview

---

## Key Concepts to Understand

### 1. **Agent Types**
- **Remote Agents**: Connect via ACP (WebSocket) or custom protocol
- **Local LLM Agents**: Call LLM APIs directly (OpenAI, Claude, etc)

### 2. **Communication Protocols**
- **ACP**: JSON-RPC 2.0 over WebSocket (app ↔ remote agent)
- **LLM APIs**: REST with SSE streaming (app → LLM provider)

### 3. **Tool System**
- **Skills**: Markdown files injected into system prompt
- **Models**: Custom tool definitions in registry
- **CLI Tools**: External executables with JSON stdio
- **OS Tools**: Built-in system operations
- **UI Components**: Interactive elements (forms, buttons, etc)

### 4. **Group Modes**
- **Standard**: Sequential agent turns (admin coordinates)
- **Planning**: Agent generates JSON plan, user approves tasks
- **Flow**: Auto-execute multi-stage workflow

### 5. **Data Flow**
```
User Input → ChatService → Agent Handler → Response Stream → UI Render → Persistence
```

---

## Recommended Learning Sequence

1. **Day 1**: Core concepts
   - Read: README.md, QUICK_START_GUIDE.md, ARCHITECTURE_DIAGRAM.txt
   - Time: 30 minutes

2. **Day 2**: Message flow
   - Read: chat_service.dart, chat_screen.dart, message_bubble.dart
   - Code: Study how messages flow from input to display
   - Time: 90 minutes

3. **Day 3**: Agent communication
   - Read: local_llm_agent_service.dart, acp_agent_connection.dart, remote_agent_service.dart
   - Code: Understand agent routing and response handling
   - Time: 90 minutes

4. **Day 4**: Data & persistence
   - Read: local_database_service.dart, models/message.dart, models/channel.dart
   - Code: Explore database schema and CRUD operations
   - Time: 60 minutes

5. **Day 5**: Configuration & tools
   - Read: skill_registry.dart, cli_tool_registry.dart, os_tool_registry.dart
   - Code: Learn how to extend the system
   - Time: 90 minutes

6. **Day 6**: Advanced features
   - Read: group_orchestration_service.dart, planning_helpers.dart, flow_executor.dart
   - Code: Understand multi-agent coordination
   - Time: 90 minutes

---

## Quick Lookup Table

| Want to find... | Read this file |
|---|---|
| How messages are sent | chat_service.dart |
| How messages are displayed | chat_screen.dart + message_bubble.dart |
| How to add new LLM provider | local_llm_agent_service.dart |
| How remote agents connect | acp_agent_connection.dart |
| How database works | local_database_service.dart |
| How to add skills | skill_registry.dart |
| How to add tools | cli_tool_registry.dart or os_tool_registry.dart |
| How groups work | group_orchestration_service.dart |
| How planning mode works | planning_helpers.dart |
| How forms work | form_bubble.dart + ui_component_registry.dart |
| Configuration options | env_config.dart + app_config.dart |
| Permissions | permission_service.dart |
| Desktop multi-window | sub_window_app.dart |
| Mobile vs desktop layout | layout_utils.dart |
| Logging | logger_service.dart |
| Token tracking | inference_log_service.dart |


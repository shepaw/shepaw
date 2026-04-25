# ShePaw Project Exploration Report

## Project Overview

**ShePaw** is a comprehensive cross-platform Flutter application for interacting with and managing multiple AI assistants (agents). It's designed with a local-first philosophy where all data stays on the user's device.

### Project Type
- **Framework**: Flutter 3.x / Dart 3.0+
- **Application Type**: Desktop & Mobile App (iOS, Android, macOS, Windows, Web)
- **Architecture**: Service-oriented with Provider state management
- **Database**: SQLite + Hive + SharedPreferences

---

## Technology Stack

### Core Framework
- **Flutter**: 3.x with Material Design 3
- **Dart**: 3.0+
- **State Management**: Provider 6.1.1, Get 4.6.6

### Networking & Communication
- **HTTP Client**: `dio` (5.4.0), `http` (1.1.2)
- **WebSocket**: `web_socket_channel` (2.4.0)
- **Protocol**: JSON-RPC 2.0 based ACP (Agent Communication Protocol)

### Data Persistence
- **SQLite**: `sqflite` (2.3.0) - Main database
- **Local Storage**: 
  - Hive (2.2.3) - Fast key-value store
  - SharedPreferences (2.2.2) - App preferences
  - Flutter Secure Storage (9.0.0) - Encrypted sensitive data

### Security
- **Encryption**: `crypto` (3.0.3), `encrypt` (5.0.3)
- **Biometric Auth**: `local_auth` (2.1.8), `flutter_secure_storage` (9.0.0)
- **Hash**: `crypto` for password hashing

### UI/Media
- **UI Components**: 
  - `flutter_svg` (2.0.9)
  - `cached_network_image` (3.3.0)
  - `emoji_picker_flutter` (3.1.0)
- **Markdown**: `flutter_markdown` (0.6.18), `markdown` (7.3.0)
- **Code Highlighting**: `flutter_highlight` (0.7.0), `highlight` (0.7.0)
- **Multimedia**:
  - Audio: `record` (5.1.2), `audioplayers` (6.1.0)
  - Images: `image_picker` (1.0.7), `file_picker` (8.0.0)
  - Desktop Clipboard: `pasteboard` (0.3.0)

### Notifications & Permissions
- `flutter_local_notifications` (18.0.1)
- `local_notifier` (0.1.6) - Windows notifications
- `permission_handler` (11.2.0)
- `flutter_foreground_task` (8.10.0) - Android background services

### Vector DB & Embedding
- `veda` (0.1.0) - Vector database
- `tflite_flutter` (0.12.1) - TensorFlow Lite models

### Utilities
- UUID: `uuid` (4.3.3)
- Localization: `intl` (0.20.2), Flutter i18n system
- Logging: `logger` (2.0.2)
- Archiving: `archive` (3.4.9)
- File Operations: `path_provider` (2.1.1), `path` (1.8.3)
- Desktop: `desktop_multi_window` (0.3.0)
- URL Handling: `url_launcher` (6.2.2)
- App Info: `package_info_plus` (8.0.0)

---

## Project Structure

```
shepaw/
├── lib/
│   ├── main.dart                          # App entry point
│   ├── sub_window_app.dart               # Desktop multi-window support
│   ├── models/                           # 31 data model files
│   │   ├── agent.dart                    # Agent model
│   │   ├── remote_agent.dart             # Remote Agent (ACP + Local LLM)
│   │   ├── channel.dart                  # Channel/conversation model
│   │   ├── message.dart                  # Message model
│   │   ├── acp_protocol.dart            # ACP JSON-RPC protocol definitions
│   │   ├── llm_provider_config.dart     # LLM provider config
│   │   ├── model_definition.dart        # Tool model definitions
│   │   ├── model_routing_config.dart    # Multi-modal routing config
│   │   ├── prompt_stack_config.dart     # Prompt configuration
│   │   ├── planning_models.dart         # Planning mode task models
│   │   ├── tool_config.dart             # Tool configuration
│   │   └── ...
│   │
│   ├── services/                         # 69 service files
│   │   ├── chat_service.dart            # Main chat/message hub
│   │   ├── local_database_service.dart  # SQLite database service
│   │   ├── local_llm_agent_service.dart # Local LLM agent execution
│   │   ├── remote_agent_service.dart    # Remote agent lifecycle management
│   │   ├── acp_agent_connection.dart    # WebSocket connection (JSON-RPC 2.0)
│   │   ├── acp_hub_handlers.dart        # Hub request handlers
│   │   ├── acp_server_service.dart      # ACP server (receiving connections)
│   │   ├── skill_registry.dart          # Markdown-based skills registry
│   │   ├── model_registry.dart          # Tool model definitions registry
│   │   ├── cli_tool_registry.dart       # External CLI tools registry
│   │   ├── ui_component_registry.dart   # UI components for agents
│   │   ├── local_api_service.dart       # Local API endpoints
│   │   ├── tool_config_service.dart     # Tool configuration service
│   │   ├── she_service.dart             # "She" AI companion service
│   │   ├── inference_log_service.dart   # Token usage & inference logging
│   │   ├── trace_service.dart           # Request tracing
│   │   │
│   │   ├── group/                       # Group orchestration (9 files)
│   │   │   ├── group_orchestration_service.dart
│   │   │   ├── group_agent_executor.dart
│   │   │   ├── planning_helpers.dart
│   │   │   ├── group_prompt_builder.dart
│   │   │   ├── group_interaction_handler.dart
│   │   │   └── ...
│   │   │
│   │   ├── messaging/                   # Messaging sub-service
│   │   ├── network/                     # Network utilities
│   │   ├── session/                     # Session management
│   │   ├── task/                        # Task execution models
│   │   └── ... (50+ total)
│   │
│   ├── screens/                         # 44 UI screens
│   │   ├── chat_screen.dart            # Main chat interface
│   │   ├── home_screen.dart            # Mobile home
│   │   ├── desktop_home_screen.dart    # Desktop home
│   │   ├── add_remote_agent_screen.dart # Agent setup
│   │   ├── agent_detail_screen.dart    # Agent configuration
│   │   ├── create_group_screen.dart    # Group creation
│   │   ├── cli_config_management_screen.dart # Tool configuration
│   │   └── ... (40+ total)
│   │
│   ├── widgets/                         # 29 UI components
│   │   ├── chat/                        # Chat-specific widgets
│   │   │   ├── chat_input_area.dart
│   │   │   ├── chat_message_list.dart
│   │   │   ├── plan_approval_card.dart
│   │   │   ├── task_board_widget.dart
│   │   │   └── ... (12 files)
│   │   ├── message_bubble.dart          # Base message rendering
│   │   ├── form_bubble.dart             # Interactive form UI
│   │   ├── action_confirmation_buttons.dart
│   │   ├── model_routing_config_card.dart
│   │   ├── skill_config_card.dart
│   │   └── ... (29 total)
│   │
│   ├── providers/                       # State management (Provider)
│   │   ├── app_state.dart
│   │   ├── notification_provider.dart
│   │   └── locale_provider.dart
│   │
│   ├── clis/                            # CLI commands system
│   │   └── shepaw/
│   │       ├── shepaw_cli.dart         # CLI entry point
│   │       ├── os/                     # OS commands
│   │       │   ├── os_tool_registry.dart
│   │       │   ├── os_cli_namespace.dart
│   │       │   ├── command/            # Shell commands
│   │       │   ├── file/               # File operations
│   │       │   ├── process/            # Process management
│   │       │   ├── app/                # App control
│   │       │   └── macos/              # macOS-specific
│   │       ├── tools/                  # Tools commands
│   │       ├── web/                    # Web tools
│   │       ├── network/                # Network tools
│   │       ├── chat/                   # Chat commands
│   │       ├── agents/                 # Agent commands
│   │       ├── context/                # Context commands
│   │       └── ... (27+ namespaces)
│   │
│   ├── config/                          # Configuration
│   │   ├── app_config.dart
│   │   └── env_config.dart
│   │
│   ├── l10n/                            # Internationalization (EN/ZH)
│   └── utils/                           # Utilities
│
├── test/                                # 18 test files
├── docs/                                # Documentation
│   ├── USER_GUIDE.md (Chinese)
│   ├── USER_GUIDE_EN.md (English)
│   ├── agent_integration_guide.md       # ACP SDK reference
│   ├── remote_llm_agent_integration.md  # Third-party agent integration
│   ├── tool_model_architecture.md
│   └── group_chat_flow.md
├── scripts/mock_agents/                 # Mock agent test environment
├── android/, ios/, macos/, windows/, web/ # Platform entry points
├── pubspec.yaml                         # Dependencies
└── BUILD_GUIDE.md, DEVELOPMENT.md       # Dev documentation
```

---

## Key Architecture Components

### 1. **Agent System**

#### Agent Types
- **Remote Agents** (via ACP Protocol or LLM API)
  - WebSocket-based bidirectional communication (JSON-RPC 2.0)
  - Token-based authentication
  - Connection state tracking
- **Local LLM Agents** (Direct API)
  - OpenAI-compatible, Claude, Gemini, DeepSeek, Qwen, GLM, Kimi, Ollama
  - Streaming HTTP responses (SSE)
  - No backend required

#### Agent Model (`RemoteAgent`)
```dart
class RemoteAgent {
  final String id;                          // UUID
  final String name;
  final String avatar;
  final String bio;
  final String token;                       // Auth token
  final String endpoint;                    // WebSocket/HTTP URL
  final ProtocolType protocol;              // 'acp' or 'custom'
  final ConnectionType connectionType;      // 'websocket' or 'http'
  final AgentStatus status;                 // online/offline/error
  final Map<String, dynamic> metadata;      // Config (LLM provider, etc)
  final Map<String, dynamic> capabilities;  // Tool definitions
}
```

### 2. **Communication Protocols**

#### ACP Protocol (Agent Communication Protocol)
- **Base**: JSON-RPC 2.0 over WebSocket
- **Direction**: Bidirectional (app ↔ agent)
- **Key Operations**:
  - `agent.chat` - Send message to agent
  - `agent.cancelTask` - Cancel ongoing task
  - `ui.*` - UI notifications (text, forms, confirmations, etc)
  - `hub.*` - Hub requests (file transfer, tool calls, etc)
- **File**: `lib/models/acp_protocol.dart`
- **Implementation**: 
  - Client: `lib/services/acp_agent_connection.dart`
  - Server: `lib/services/acp_server_service.dart`

#### Local LLM API Integration
- **Supported**: OpenAI, Claude, GLM, Gemini, Ollama, etc
- **Streaming**: Server-Sent Events (SSE)
- **Tool Calling**: Native support for interactive UI tools
- **File**: `lib/services/local_llm_agent_service.dart`

### 3. **Chat & Messaging System**

#### Chat Service (`ChatService`)
The central hub for all message operations:
- **Responsibilities**:
  - Message CRUD operations
  - Connection pooling (ACP agents)
  - Stream management for real-time updates
  - Task execution coordination
  - Group orchestration delegation
  - History management
- **Key Methods**:
  - `sendMessage()` - Send to single agent or group
  - `sendMessageToGroup()` - Multi-agent coordination
  - `loadChannelMessages()` - History retrieval
  - `createChannel()` - Initialize conversation
- **Database Backend**: `LocalDatabaseService` (SQLite)

#### Message Model
```dart
class Message {
  final String id;
  final MessageFrom from;              // Sender info
  final MessageFrom? to;               // Optional recipient
  final String channelId;              // Conversation ID
  final MessageType type;              // text/image/file/audio/system
  final String content;                // Message body
  final int timestampMs;
  final String? replyTo;               // Reply-to reference
  final Map<String, dynamic>? metadata; // Attachments, metadata
}
```

### 4. **Tool & Skill System**

#### Tool Registries (3 types)

##### A. Skill Registry (`SkillRegistry`)
- **Format**: Markdown-based instruction sets
- **Location**: `~/shepaw/skills/`
- **Structure**: 
  - Directory: skill name
  - File: `SKILL.md` with YAML front matter
  - Optional: auxiliary scripts/files
- **Usage**: Injected into system prompt for local LLM agents
- **File**: `lib/services/skill_registry.dart`

##### B. Model Registry (`ModelRegistry`)
- **Type**: Tool model definitions (not LLM models, but model runners)
- **Storage**: SharedPreferences (JSON)
- **Purpose**: Models that can be called as tools by the main LLM
- **Example**: Code review model, translation model, etc
- **File**: `lib/services/model_registry.dart`

##### C. CLI Tool Registry (`CliToolRegistry`)
- **Format**: External executable tools with JSON stdin/stdout
- **Location**: `~/shepaw/cli-tools/`
- **Structure**:
  - Directory: tool name
  - File: `cli-tool.json` manifest
  - File: handler (script/binary)
- **Communication**: JSON protocol
- **File**: `lib/services/cli_tool_registry.dart`

##### D. OS Tool Registry (`OsToolRegistry`)
- **Type**: Built-in OS operations
- **Operations**: 
  - Shell commands (`os.command.exec`)
  - File I/O (`os.file.*`)
  - Process management (`os.process.*`)
  - System info (`os.command.sysinfo`)
  - Clipboard operations
- **Risk Levels**: safe / lowRisk / highRisk
- **Platform Filtering**: per-tool support matrix
- **File**: `lib/clis/shepaw/os/os_tool_registry.dart`

##### E. UI Component Registry (`UIComponentRegistry`)
- **Type**: Interactive UI components for agent responses
- **Components**: Forms, buttons, select menus, action confirmations
- **LLM Integration**: Exported as tool definitions
- **File**: `lib/services/ui_component_registry.dart`

### 5. **Group Orchestration**

#### Three Modes

1. **Standard Mode** (Round-robin discussion)
   - Admin coordinates agents
   - Up to 50 rounds
   - Each agent sees previous responses
   - Sequential execution

2. **Planning Mode** (Agent-generated task plan)
   - Agent generates JSON task plan
   - User reviews and approves
   - Tasks execute in approval order
   - Supports planning_helpers for task board
   - File: `lib/services/group/planning_helpers.dart`

3. **Flow Mode** (Multi-stage workflow)
   - Agent produces multi-stage workflow
   - System drives automated execution
   - Pause / Resume / Skip / Abort controls
   - File: `lib/services/flow_executor.dart`

#### Group Services
- **`GroupOrchestrationService`**: Main coordinator
- **`GroupAgentExecutor`**: Per-agent execution
- **`GroupDispatchParser`**: Parse structured JSON responses
- **`GroupPromptBuilder`**: System prompt + modality detection
- **`GroupInteractionHandler`**: Admin interaction decisions

### 6. **Configuration & Settings**

#### Environment Configuration (`EnvConfig`)
```dart
// Environment variables (build-time)
ENVIRONMENT: 'development' | 'staging' | 'production'
API_URL: API base URL
WS_URL: WebSocket URL
LOG_LEVEL: 'debug' | 'info'
ENABLE_LOGGING: true/false
NETWORK_TIMEOUT: seconds
WS_RECONNECT_INTERVAL: seconds
WS_MAX_RECONNECT_ATTEMPTS: count
```

#### App Configuration (`AppConfig`)
- Development: localhost:3002
- Staging: staging-api.shepaw.com
- Production: api.shepaw.com

#### SharedPreferences Keys
- `acp_server_port`: ACP server port (default 18790)
- `acp_server_enabled`: Enable/disable ACP server
- `acp_server_token`: Authentication token
- `tool_model_definitions`: Tool model registry (JSON)
- And more for app state, user preferences, etc

### 7. **CLI System**

#### CLI Architecture
- **Entry**: `lib/clis/shepaw/shepaw_cli.dart`
- **Namespaces**: Hierarchical command structure
  - `os.*` - Operating system commands
  - `chat.*` - Chat operations
  - `agents.*` - Agent management
  - `tools.*` - Tool registry
  - `context.*` - Context management
  - `web.*` - Web operations
  - `meta.*` - Metadata
  - `network.*` - Network utilities
  - `profile.*` - User profile
  - `system.*` - System operations
  - `memory.*` - Memory management
- **Execution**: Async executor pattern
- **Files**: `lib/clis/shepaw/`

---

## UI/UX Architecture

### Screens (44 Total)

#### Main Navigation
- `adaptive_home_screen.dart` - Routes to mobile/desktop
- `home_screen.dart` - Mobile home (agent/channel list)
- `desktop_home_screen.dart` - Desktop home (split panel)

#### Chat & Messaging
- `chat_screen.dart` - Main chat interface
- `channel_list_screen.dart` - Conversation list
- `incoming_message_screen.dart` - Agent-initiated messages

#### Agent Management
- `agent_list_screen.dart` - Agents directory
- `agent_detail_screen.dart` - Agent config & settings
- `add_remote_agent_screen.dart` - New agent setup (49KB - complex)
- `remote_agent_detail_screen.dart` - Remote agent specifics

#### Group Features
- `create_group_screen.dart` - Group creation wizard
- `group_detail_screen.dart` - Group management
- `agent_collaboration_screen.dart` - Collaboration UI

#### Configuration & Settings
- `cli_config_management_screen.dart` - OS/CLI tool config (150KB!)
- `agent_cli_commands_management_screen.dart` - Command management
- `tool_config_service.dart` - Tool configuration UI
- `skill_config_card.dart` - Skill management

#### Monitoring & Analytics
- `inference_log_screen.dart` - Token usage logs
- `channel_trace_screen.dart` - Request tracing
- `log_viewer_screen.dart` - Application logs
- `agent_token_display_screen.dart` - Token statistics

#### Other Screens
- `password_setup_screen.dart` - Initial password setup
- `login_screen.dart` - Authentication
- `agent_approval_screen.dart` - Permission approval
- `image_viewer_screen.dart` - Image display

### Chat Widgets (12+ Components)

#### Core Chat Components
- `chat_input_area.dart` (41KB) - Message input with file upload
- `chat_message_list.dart` - Scrollable message feed
- `chat_app_bar.dart` - Header with agent info
- `chat_menu.dart` - Context menu

#### Message Types
- `message_bubble.dart` (22KB) - Base text message rendering
- `image_message_bubble.dart` - Image display
- `file_message_bubble.dart` - File attachment
- `voice_message_bubble.dart` - Audio message
- `collapsible_message_bubble.dart` - Expandable content

#### Interactive Components
- `form_bubble.dart` (22KB) - Form input UI
- `single_select_bubble.dart` - Radio buttons
- `multi_select_bubble.dart` - Checkboxes
- `action_confirmation_buttons.dart` - Action prompts
- `plan_approval_card.dart` (12KB) - Planning mode approval
- `task_board_widget.dart` (14KB) - Flow mode task board

#### Management & Config
- `model_routing_config_card.dart` (41KB) - Multi-modal routing
- `model_config_card.dart` - Model selection
- `skill_config_card.dart` - Skill management
- `cli_command_config_card.dart` - CLI command config
- `os_tool_config_card.dart` - OS tool management
- `os_tool_confirmation_dialog.dart` - Permission dialogs

#### Utility Widgets
- `message_search_delegate.dart` - Full-text search
- `agent_search_delegate.dart` - Agent lookup
- `session_list_panel.dart` - DM session sidebar
- `group_session_list_panel.dart` - Group sidebar
- `update_dialog.dart` - App update notifications

---

## Database Schema

### SQLite Tables (via `LocalDatabaseService`)

#### Core Tables
- **agents**: Remote agent definitions
- **channels**: Conversations (1:1 DMs and group channels)
- **messages**: Chat messages
- **attachments**: File metadata
- **remote_agent_tokens**: Authentication tokens

#### Configuration Tables
- **tool_results**: Tool execution outputs
- **trace_log**: Request tracing
- **inference_log**: Token usage & API call logs
- **she_memory**: "She" agent memory entries
- **she_profile**: "She" agent profile
- **agent_memory**: Agent-specific memory

#### Session Tables
- **group_sessions**: Group channel session history
- **group_session_messages**: Messages within group sessions

### SharedPreferences Data
- App state (selected agent, channel, etc)
- User preferences (theme, language, etc)
- Tool model definitions (JSON)
- API keys (encrypted via Secure Storage)
- Connection tokens

---

## Security Model

### Three-Tier Permission System

1. **SAFE** - No confirmation required
   - Read-only operations
   - Display operations

2. **WARNING** - User confirmation required
   - File operations
   - Network requests
   - System queries

3. **DANGEROUS** - Additional authorization
   - Shell command execution
   - Process termination
   - System modification

### Data Protection
- **API Keys**: Flutter Secure Storage (encrypted)
- **Passwords**: `crypto` with salt/hash
- **Messages**: Local SQLite (optional at-rest encryption via sqflite)
- **Biometric**: Native biometric auth (Face ID / Touch ID / fingerprint)

### Network Security
- HTTPS/WSS for all remote connections
- Token-based authentication (ACP protocol)
- WebSocket message signing (optional)

---

## Key Files Reference

### Essential Services (Must Know)
1. **`chat_service.dart`** (45KB) - Central message hub
2. **`local_database_service.dart`** (49KB) - Database wrapper
3. **`local_llm_agent_service.dart`** (56KB) - LLM execution
4. **`acp_agent_connection.dart`** (20KB) - WebSocket client
5. **`remote_agent_service.dart`** (18KB) - Agent lifecycle
6. **`she_service.dart`** (29KB) - "She" companion agent

### Configuration & Registry
1. **`skill_registry.dart`** - Markdown skill loading
2. **`model_registry.dart`** - Tool model registry
3. **`cli_tool_registry.dart`** - External CLI tools
4. **`os_tool_registry.dart`** - OS command definitions

### Group Orchestration
1. **`group_orchestration_service.dart`** (82KB) - Main coordinator
2. **`group_agent_executor.dart`** (39KB) - Agent execution
3. **`flow_executor.dart`** (20KB) - Workflow execution

### Screens (Most Complex)
1. **`chat_screen.dart`** (84KB) - Main chat UI
2. **`cli_config_management_screen.dart`** (150KB!) - Tool config
3. **`add_remote_agent_screen.dart`** (48KB) - Agent setup
4. **`desktop_home_screen.dart`** (40KB) - Desktop layout

---

## Configuration Mechanisms

### 1. **Environment Variables** (Build-Time)
```bash
ENVIRONMENT=development
API_URL=http://localhost:8080
WS_URL=ws://localhost:8080/ws
LOG_LEVEL=debug
ENABLE_LOGGING=true
NETWORK_TIMEOUT=30
```

### 2. **SharedPreferences** (Runtime)
- Per-agent configuration
- UI preferences
- App state persistence
- Tool definitions (JSON)

### 3. **Secure Storage** (Encrypted)
- API keys
- Authentication tokens
- Passwords

### 4. **File-Based Configuration**
- Skills: `~/shepaw/skills/SKILL.md`
- CLI Tools: `~/shepaw/cli-tools/cli-tool.json`
- Local database: `~/.local/share/shepaw/` (Linux/macOS)

### 5. **In-App Configuration Screens**
- `cli_config_management_screen.dart` - OS tool settings
- `add_remote_agent_screen.dart` - Agent parameters
- Settings screens - User preferences

---

## Chat & Conversation UI Flow

### Message Flow Architecture
```
User Input (chat_input_area.dart)
    ↓
ChatService.sendMessage()
    ├─ For Remote Agent (ACP):
    │  ├─ Get ACPAgentConnection (pooled)
    │  ├─ Send via WebSocket
    │  └─ Stream responses via TaskCallbacks
    │
    └─ For Local LLM Agent:
       ├─ LocalLLMAgentService.chat()
       ├─ Stream SSE responses
       └─ Handle tool calls
    ↓
Chat Screen displays:
├─ Message bubbles (message_bubble.dart)
├─ Streaming text (typing animation)
├─ Interactive components (forms, buttons, etc)
├─ File/image/audio attachments
└─ Tool execution results
```

### Real-Time Updates
- **StreamControllers** per channel: `_messageControllers` (keyed by channelId)
- **Provider** notifies listeners of state changes
- **UI rebuilds** on stream updates
- **Polling-free**: Event-driven architecture

### Response Types
1. **Text Content**: Streamed tokens
2. **Action Buttons**: Interactive confirmations
3. **Forms**: User input collection
4. **File Upload**: Attachment handling
5. **Message Metadata**: Task state tracking
6. **History Requests**: Context window management

---

## Supported LLM Providers

### Cloud Providers
- **OpenAI**: GPT-4, GPT-4o
- **Anthropic Claude**: Claude 3 family
- **Google Gemini**: Gemini models
- **DeepSeek**: DeepSeek API
- **Qwen**: Alibaba Qwen
- **GLM (Zhipu)**: GLM models
- **Kimi (Moonshot)**: Moonshot API
- **Grok**: xAI Grok
- **Hunyuan**: Tencent Hunyuan

### Local Options
- **Ollama**: Any locally deployed model (llama3, llava, etc)

### Custom
- Any service with OpenAI-compatible API

---

## Platform Support & Multi-Window

### Supported Platforms
- ✅ iOS (with biometric, audio, etc)
- ✅ Android (with biometric, audio, foreground service)
- ✅ macOS (native notifications, desktop multi-window)
- ✅ Windows (native notifications, desktop multi-window)
- ✅ Web (limited multimedia)

### Desktop Multi-Window
- Entry: `sub_window_app.dart`
- Package: `desktop_multi_window` (0.3.0)
- Purpose: Detached agent windows, settings panels
- Data Sync: SharedPreferences across windows

### Adaptive Layout
- Mobile: Single-column chat screen
- Tablet/Desktop: Split-panel (sidebar + chat)
- Logic: `layout_utils.dart`

---

## Summary: Key Takeaways

### Architecture Highlights
1. **Service-Oriented**: ~70 services for separation of concerns
2. **Event-Driven**: StreamControllers for real-time updates
3. **Multi-Protocol**: ACP (WebSocket JSON-RPC 2.0) + Direct LLM APIs
4. **Local-First**: All data on-device (SQLite + Hive)
5. **Extensible**: Plugin system for skills, models, CLI tools, UI components
6. **Security-First**: 3-tier permissions, encrypted storage, biometric auth

### Tech Stack Highlights
- Flutter 3.x for cross-platform UI
- Provider for state management
- SQLite + Hive for persistence
- JSON-RPC 2.0 for agent communication
- Markdown for skill definitions
- Multi-modal support (text, image, audio, video, files)

### Complex Areas
1. **Group Orchestration** (82KB service) - Complex multi-agent coordination
2. **CLI Tool Configuration** (150KB screen) - Tool management UI
3. **Message Bubble Rendering** (22KB) - Rich content display
4. **Local LLM Integration** (56KB) - Provider compatibility layer

### Integration Points for Extension
- Add new LLM provider: Update `LocalLLMAgentService`
- Add new tool: Create in `OsToolRegistry` or import via CLI tools
- Add new UI component: Register in `UIComponentRegistry`
- Add new skill: Drop `SKILL.md` in `~/shepaw/skills/`
- Add agent: Use `RemoteAgentService.createAgent()` or `add_remote_agent_screen.dart`

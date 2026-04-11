# Paw (Shepaw) - Comprehensive Codebase Overview

## Project Summary

**Paw** is a sophisticated Flutter-based mobile/desktop platform for agent communication and orchestration. It's a secure platform that enables:
- Multi-agent conversations and group orchestration
- Direct messaging (DM) with remote agents
- Dynamic agent UI interactions (forms, file uploads, selections)
- Local agent persistence and memory management
- ACP (Agent Communication Protocol) WebSocket server for inbound agent connections
- Complex group orchestration with planning, flow execution, and session management
- Built-in "She" guardian agent with personality and memory

**Tech Stack:**
- **Frontend:** Flutter (Dart 3.0+)
- **Database:** SQLite (via sqflite)
- **Storage:** Local file system + shared preferences
- **State Management:** Provider + GetX
- **Network:** WebSocket + HTTP/Dio
- **Security:** Flutter Secure Storage, local authentication, encryption
- **Platforms:** iOS, Android, macOS, Windows, Linux, Web

---

## 1. Overall Project Structure

```
shepaw/
├── lib/                           # Main Flutter application code
│   ├── main.dart                 # Entry point, app initialization
│   ├── models/                   # Data models (31 files)
│   ├── services/                 # Business logic services (69 files)
│   ├── screens/                  # UI screens (44 files)
│   ├── widgets/                  # Reusable UI components (29 files)
│   ├── providers/                # State providers (4 files)
│   ├── utils/                    # Utility functions (7 files)
│   ├── clis/                     # CLI tools & commands
│   ├── controllers/              # Business controllers (3 files)
│   ├── config/                   # App configuration (2 files)
│   └── l10n/                     # Localization (English/Chinese)
├── pubspec.yaml                  # Flutter dependencies
├── test/                         # Test files
├── android/                      # Android-specific code
├── ios/                          # iOS-specific code
├── macos/                        # macOS-specific code
├── windows/                      # Windows-specific code
├── linux/                        # Linux-specific code
├── web/                          # Web-specific code
└── docs/                         # Documentation

Version: 1.0.1+1
SDK: >=3.0.0 <4.0.0
```

---

## 2. Key Directories and Their Purposes

### **lib/models/** (31 files)
Core data structures:
- `remote_agent.dart` - Agent model with metadata (OS tools, skills, CLI commands, model routing)
- `message.dart` - Message structure (text, image, file, audio, system)
- `channel.dart` - Channel/group model (DM, group, public with members and modes)
- `acp_protocol.dart` - ACP protocol requests/responses/notifications
- `planning_models.dart` - ExecutionPlan, Stage structures for group planning
- `prompt_stack_config.dart` - Configurable prompt section injection for She
- `llm_provider_config.dart` - LLM provider configurations
- `agent_memory_entry.dart` - Long-term memory structures
- `tool_execution_result.dart` - Tool execution results
- `trace_models.dart` - Inference trace/log models
- `cognition.dart` - User profile and cognition data
- `cli_tool_definition.dart` - CLI tool schema definitions
- `update_model.dart` - App update information

### **lib/services/** (69 files)
Business logic and infrastructure:

#### **Core Services:**
- `local_database_service.dart` - SQLite database management (19 schema versions)
- `local_api_service.dart` - Local data access API
- `local_storage_service.dart` - SharedPreferences wrapper

#### **Messaging:**
- `messaging/agent_messaging_service.dart` - Agent message handling
- `messaging/acp_protocol_handler.dart` - ACP protocol processing
- `messaging/local_llm_handler.dart` - Local LLM message routing
- `chat_service.dart` - Main chat orchestration (ActiveTask, GroupActiveTask)

#### **Agent Management:**
- `remote_agent_service.dart` - Remote agent lifecycle & health checks
- `acp_server_service.dart` - WebSocket server for inbound agents
- `acp_agent_connection.dart` - Individual agent connections
- `acp_hub_handlers.dart` - Hub request handlers (hub.* methods)

#### **Group Orchestration:**
- `group/group_orchestration_service.dart` - Main group chat orchestration
- `group/group_agent_executor.dart` - Individual agent execution
- `group/group_prompt_builder.dart` - System prompt construction
- `group/group_dispatch_parser.dart` - JSON dispatch block parsing
- `group/group_interaction_handler.dart` - UI interaction handling
- `group/planning_helpers.dart` - Planning mode helpers
- `group/group_session_service.dart` - Group session management

#### **She (Guardian Agent):**
- `she_service.dart` - She initialization, memory, profile management
- `she_memory_db_service.dart` - She's long-term memory database
- `she_profile_database_service.dart` - She's user profile database
- `agent_memory_db_service.dart` - Agent-specific memory
- `agent_memory_biz_service.dart` - Memory business logic
- `cognition_service.dart` - User cognition/profile management

#### **Sessions & History:**
- `session/session_history_service.dart` - DM session history
- `session_utils.dart` - Session utilities

#### **Flow Execution:**
- `flow_executor.dart` - ExecutionPlan-driven group orchestration

#### **Task Management:**
- `task/task_models.dart` - ActiveTask, GroupActiveTask models
- `task/plan_approval_service.dart` - Planning mode approval workflow

#### **Skills & CLI Tools:**
- `skill_registry.dart` - Markdown-based skill registration/loading
- `cli_tool_registry.dart` - External CLI tool loading
- `model_registry.dart` - Tool model registry (vision, audio, etc.)

#### **Utilities:**
- `file_download_service.dart` - File downloads
- `attachment_service.dart` - File attachment handling
- `notification_service.dart` - Local notifications
- `logger_service.dart` - File-based logging
- `permission_service.dart` - ACP-based permission management
- `biometric_service.dart` - Biometric authentication
- `audio_recording_service.dart` - Voice recording
- `audio_playback_service.dart` - Voice playback
- `channel_tunnel_service.dart` - Public network tunneling
- `trace_service.dart` - Inference tracing/analytics
- `error_handler_service.dart` - Error handling
- `data_export_import_service.dart` - Data backup/restore

#### **Infrastructure:**
- `password_service.dart` - Password management
- `token_service.dart` - Token lifecycle
- `update_notification_service.dart` - App update notifications
- `app_lifecycle_service.dart` - App lifecycle hooks
- `foreground_task_service.dart` - Background task management
- `inference_log_service.dart` - Inference logging
- `connection_manager.dart` - Connection pooling
- `protocol_router.dart` - Protocol routing

### **lib/screens/** (44 files)
UI screens organized by feature:
- `home_screen.dart` - Main chat list view
- `desktop_home_screen.dart` - Desktop layout variant
- `chat_screen.dart` - Single DM/group conversation
- `agent_list_screen.dart` - Browse agents
- `remote_agent_list_screen.dart` - Remote agent management
- `agent_detail_screen.dart` - Agent profile & metadata
- `remote_agent_detail_screen.dart` - Remote agent configuration
- `create_group_screen.dart` - Group creation wizard
- `group_detail_screen.dart` - Group settings
- `channel_list_screen.dart` - All channels/conversations
- `settings_screen.dart` - App settings
- `user_profile_settings_screen.dart` - She's user profile (core + extended fields)
- `agent_memory_detail_screen.dart` - Agent memory inspection
- `cli_config_management_screen.dart` - CLI tool configuration
- `model_management_screen.dart` - Model/capability management
- `skill_management_screen.dart` - Skill browser
- `inference_log_screen.dart` - Inference analytics
- `channel_trace_screen.dart` - Conversation trace/audit
- `login_screen.dart` - Authentication
- `password_setup_screen.dart` - Initial password setup
- `permission_request_screen.dart` - Permission approval dialogs
- `agent_approval_screen.dart` - Agent approval flows
- Various utility/detail screens

### **lib/widgets/** (29 files)
Reusable components:
- Message display widgets
- Markdown/code rendering
- File/image viewers
- Form inputs
- Chat UI elements
- Notification panels
- Settings panels

### **lib/clis/** (CLI Tools)
Shepaw CLI implementation:
- `shepaw/shepaw_cli.dart` - Main CLI entry point
- `shepaw/agents/` - Agent management commands (list, get, chat, memory, cognition)
- `shepaw/memory/` - Memory operations (write, query, append)
- `shepaw/skills_namespace.dart` - Skill enumeration
- `shepaw/tools/` - Web tools (search, fetch, brave_search, tavily)
- `shepaw/chat/` - Chat operations (channels, messages)
- `shepaw/context/` - Context variables
- `shepaw/meta/` - Metadata (datetime, cli_tools)
- `shepaw/external_cli_namespace.dart` - External tool loading
- `cli_base.dart` - Base CLI classes

---

## 3. Existing Database Models/Schemas

### **Main SQLite Database** (`shepaw.db`, 19 schema versions)

Located in: `lib/services/local_database_service.dart`

#### **Core Tables:**

1. **`user`** - KV store for user metadata
   - `key TEXT PRIMARY KEY`
   - `value TEXT NOT NULL`
   - `created_at TEXT`, `updated_at TEXT`

2. **`agents`** - Remote agent registry
   - `id TEXT PRIMARY KEY` (UUID)
   - `name TEXT`, `avatar TEXT`, `bio TEXT`
   - `token TEXT` (auth token)
   - `endpoint TEXT`, `protocol TEXT`, `connection_type TEXT`
   - `status TEXT` (online/offline/error)
   - `last_heartbeat INTEGER`, `connected_at INTEGER`
   - `capabilities TEXT` (JSON), `metadata TEXT` (JSON)
   - `is_pinned INTEGER` (for She)
   - `created_at INTEGER`, `updated_at INTEGER`
   - **Indexes:** token, status, last_heartbeat

3. **`agent_cards`** - A2A Agent Card cache
   - `id INTEGER PRIMARY KEY`
   - `agent_id TEXT UNIQUE`
   - `card_data TEXT` (JSON)
   - `cached_at INTEGER`

4. **`tasks`** - Generic task tracking (supports A2A and other protocols)
   - `id INTEGER PRIMARY KEY`
   - `task_id TEXT UNIQUE`
   - `agent_id TEXT`
   - `instruction TEXT`
   - `state TEXT` (pending/running/completed/error)
   - `request_data TEXT`, `response_data TEXT`
   - `created_at INTEGER`, `updated_at INTEGER`

5. **`channels`** - Conversations and groups
   - `id TEXT PRIMARY KEY` (UUID)
   - `name TEXT`, `description TEXT`
   - `type TEXT` (dm/group/public)
   - `avatar_path TEXT`, `is_private INTEGER`
   - `parent_group_id TEXT` (for group sessions)
   - `system_prompt TEXT` (custom group prompt)
   - `max_loop_rounds INTEGER` (group iteration limit)
   - `mention_mode TEXT` (adminOnly/allMembers)
   - `planning_mode INTEGER`, `flow_mode INTEGER`
   - `created_at TEXT`, `updated_at TEXT`, `created_by TEXT`
   - **Indexes:** created_by, type

6. **`channel_members`** - Group membership
   - `id INTEGER PRIMARY KEY`
   - `channel_id TEXT`, `agent_id TEXT`
   - `role TEXT` (admin/member)
   - `group_bio TEXT` (channel-specific bio override)
   - `joined_at TEXT`
   - **Constraint:** UNIQUE(channel_id, agent_id)

7. **`messages`** - All conversation messages
   - `id TEXT PRIMARY KEY`
   - `channel_id TEXT`
   - `sender_id TEXT`, `sender_type TEXT` (agent/user/system)
   - `sender_name TEXT`, `content TEXT`
   - `message_type TEXT` (text/image/file/audio/system/permissionAudit)
   - `metadata TEXT` (JSON, includes name/size/urls/file_id)
   - `reply_to_id TEXT` (threading)
   - `created_at TEXT`, `is_read INTEGER`
   - **Indexes:** channel, created_at DESC, sender_id, read status, channel+read+created

8. **`conversation_requests`** - Agent-to-agent collaboration requests
   - `id TEXT PRIMARY KEY`
   - `requester_id TEXT`, `target_id TEXT`
   - `purpose TEXT`, `status TEXT` (pending/approved/rejected)
   - `metadata TEXT`
   - `requested_at TEXT`, `responded_at TEXT`, `response_reason TEXT`

9. **`resources`** - File/media storage metadata
   - `id TEXT PRIMARY KEY`
   - `name TEXT`, `file_path TEXT`, `file_type TEXT`
   - `file_size INTEGER`, `mime_type TEXT`, `thumbnail_path TEXT`
   - `owner_id TEXT`, `owner_type TEXT` (agent/user)
   - `created_at TEXT`, `metadata TEXT`

10. **`tool_configs`** - Global tool configuration
    - `tool_name TEXT PRIMARY KEY`
    - `parameter_overrides TEXT` (JSON)
    - `has_api_key INTEGER`, `enabled INTEGER`
    - `she_exclusive INTEGER` (She-only)
    - `note TEXT`
    - `created_at INTEGER`, `updated_at INTEGER`

11. **`cli_command_configs`** - CLI command configuration
    - `command_id TEXT PRIMARY KEY`
    - `global_enabled INTEGER`, `she_only INTEGER`
    - `note TEXT`
    - `created_at INTEGER`, `updated_at INTEGER`

#### **Separate Databases:**

12. **She Memory DB** (`she_memory.db`)
    - `key TEXT PRIMARY KEY`
    - `value TEXT` (long-term memory storage)
    - **Keys:** soul, self_notes, user_info, long_term_memory, heartbeat, conversation_count, capabilities

13. **She Profile DB** (`she_profile.db`)
    - User profile fields stored as KV pairs
    - **Core:** name, age, gender, occupation, city
    - **Extended:** interests, values, goals, communication_style, work_style, life_stage, important_people, health, language, timezone, notes

14. **Agent Memory DB** (`agent_memory.db`)
    - Per-agent long-term memory storage
    - `agent_id TEXT`, `key TEXT`, `value TEXT`, timestamps

15. **Minds Database** (`minds.db`)
    - Agent-specific data structures (cognition, profiles)

16. **Tool Results Database** (`tool_results.db`)
    - Tool execution results for auditing/replay

17. **Trace Database** (`trace.db`)
    - Inference traces, logs, and analytics

---

## 4. Existing API Routes/Endpoints

### **ACP Server (WebSocket Server)**
Runs on configurable port (default: 18790), handles bi-directional agent communication.

#### **App → Agent Requests (JSON-RPC 2.0):**
```
auth.authenticate          - Agent authentication with token
agent.chat                 - Send message to agent
agent.cancelTask           - Cancel in-flight task
agent.submitResponse       - Submit UI interaction response
agent.rollback             - Rollback message history
agent.getCard              - Get agent capability card
agent.requestFileData      - Request file via binary transfer
ping                       - Heartbeat
```

#### **Agent → App Requests (hub.* methods):**
```
hub.getSessions                 - Get conversation/channel list
hub.getSessionMessages          - Retrieve message history
hub.getAgentList                - List all agents
hub.getHubInfo                  - Get app metadata
hub.sendFile                    - Send file to app
hub.initiateChat                - Agent-initiated conversation
hub.getAgentCapabilities        - Query agent capabilities
hub.subscribeChannel            - Subscribe to channel updates
hub.unsubscribeChannel          - Unsubscribe from channel
hub.getUIComponentTemplates     - Get UI template catalog
hub.getAttachmentContent        - Download attachment content
```

#### **Agent → App Notifications (UI Events):**
```
ui.textContent           - Streaming text content
ui.actionConfirmation    - Action button confirmation
ui.singleSelect          - Single-choice selection
ui.multiSelect           - Multi-choice selection
ui.fileUpload            - File upload request
ui.form                  - Structured form submission
ui.fileMessage           - File/image message (async file)
ui.messageMetadata       - Collapse/metadata blocks
ui.requestHistory        - Request older conversation history
task.started             - Task lifecycle start
task.completed           - Task lifecycle complete
task.error               - Task error notification
```

#### **Group Events:**
```
group.memberJoined      - Member joined group
group.memberLeft        - Member left group
```

#### **File Transfer:**
```
file.transferStart      - Binary file transfer start
file.transferComplete   - Transfer finished
file.transferError      - Transfer failed
```

### **Local API Service**
In-app HTTP REST-like interface (no actual HTTP server, uses LocalDatabaseService):
```
login(username, avatar)              - User authentication
getAgents()                          - Get agent list
getAgentById(id)                     - Get single agent
createAgent(agent)                   - Create local agent
updateAgent(agent)                   - Update agent
deleteAgent(id)                      - Delete agent
getChannels()                        - Get all channels
getChannelById(id)                   - Get channel details
createChannel(channel)               - Create channel/group
updateChannel(channel)               - Update channel
deleteChannel(id)                    - Delete channel
getMessages(channelId, limit)        - Get channel messages
createMessage(...)                   - Create message
sendMessage(...)                     - Send message
```

### **CLI Tool Interface** (via ShepawCLI)
Accessible to She and agents via tool execution:
```
shepaw agents list
shepaw agents get <id>
shepaw agents chat <id> <message>
shepaw agents memory write <agent_id> --key <key> --value <value>
shepaw agents memory query <agent_id> --key <key>
shepaw agents cognition write <key> <value>
shepaw agents cognition query <key>
shepaw skills list
shepaw tools list
shepaw context get <key>
shepaw meta datetime
shepaw web search <query>
shepaw web fetch <url>
shepaw chat channels
shepaw chat messages <channel_id>
```

---

## 5. Existing Task/Scheduling Related Code

### **Task Models** (`lib/services/task/task_models.dart`)

#### **ActiveTask** - Tracks in-flight DM agent tasks
```dart
class ActiveTask {
  String taskId
  String agentId, agentName
  String channelId
  String userMessageId
  String userId, userName
  
  String accumulatedContent         // Streamed text buffer
  Map<String, dynamic>? metadata
  bool isComplete
  String? errorMessage
  int startedAtMs
  bool wasInterruptedByBackground
  
  Completer<void> dbSaveCompleter   // Completes after DB persist
  
  // UI callbacks (detachable)
  void Function(String)? onStreamChunk
  void Function()? onTaskFinished
  
  // Interactive callbacks
  void Function(...)? onActionConfirmation
  void Function(...)? onSingleSelect
  void Function(...)? onMultiSelect
  void Function(...)? onFileUpload
  void Function(...)? onForm
  Future<void> Function(...)? onFileMessage
  
  // OS tool confirmation
  Future<bool> Function(...)? onOsToolConfirmation
  
  void detachUI()  // Clear all callbacks
}
```

#### **GroupActiveTask** - Tracks group agent tasks
```dart
class GroupActiveTask {
  String agentId, agentName
  String channelId
  String accumulatedContent
  bool isComplete
  
  void Function(String)? onStreamChunk
  void Function()? onTaskFinished
  void detachUI()
}
```

### **Plan Approval Service** (`lib/services/task/plan_approval_service.dart`)
Handles group planning mode (admin generates plan → user approves → execution):
- `PlanApprovalHandle` - Tracks pending plan approvals
- Stores `ExecutionPlan` pending approval
- Binds to UI for user confirmation
- Manages approval/rejection callbacks

### **Chat Service Task Management** (`lib/services/chat_service.dart`)
```dart
class ChatService {
  // Active task registry (keyed by channelId)
  Map<String, ActiveTask> _activeTasks = {}
  
  // Group tasks (keyed by channelId -> agentId)
  Map<String, Map<String, GroupActiveTask>> _activeGroupTasks = {}
  
  // Plan approvals
  PlanApprovalService _planApprovalService
  
  // Flow executors (one per group channel)
  Map<String, FlowExecutor> _activeFlowExecutors = {}
}
```

### **Session History Service** (`lib/services/session/session_history_service.dart`)
Manages conversation sessions:
- Load message history
- Delete messages/sessions
- Rollback to previous states
- Message retention policies

---

## 6. How Sessions and Agents Are Structured

### **Agent Structure** (Remote Agents)

#### **RemoteAgent Model** (`lib/models/remote_agent.dart`)
```dart
class RemoteAgent {
  // Identity
  String id                              // UUID
  String name, avatar ('🤖'), bio
  
  // Connection Config
  String token                           // Auth token
  String endpoint                        // WebSocket/HTTP URL
  ProtocolType protocol                  // acp/custom
  ConnectionType connectionType          // websocket/http
  
  // Status
  AgentStatus status                     // online/offline/error
  int? lastHeartbeat, connectedAt
  
  // Capabilities
  List<String> capabilities
  Map<String, dynamic> metadata          // Extended data
  
  bool isPinned                          // She is always pinned
  int createdAt, updatedAt
  
  // Computed Properties
  bool get isShe                         // metadata['is_she']
  bool get isOnline
  bool get allowExternalAccess
  
  Set<String> get enabledOsTools        // metadata['enabled_os_tools']
  Set<String> get enabledSkills         // metadata['enabled_skills']
  Set<String> get enabledToolModels     // metadata['enabled_tool_models']
  Set<String> get enabledCliCommands    // metadata['enabled_cli_commands']
  
  ModelRoutingConfig get modelRouting   // metadata['model_routing']
  PromptStackConfig get promptStackConfig
  bool supportsModality(modality)
}
```

#### **Special Agent: "She"** (Built-in Guardian Agent)
- **ID:** `she-builtin-agent-001`
- **Name:** "She"
- **Avatar:** 🌸
- **Pinned:** Always visible
- **Role:** Autonomous guardian with personal growth
- **Memory:** Three separate databases:
  - **She Memory** (`she_memory.db`) - Soul, self-notes, long-term memory
  - **She Profile** (`she_profile.db`) - User profile information
  - **She Metadata** - Stored in agent metadata

#### **She's Prompt Stack** (System Prompt Composition)
Layers injected per conversation (in order):
1. She core identity (immutable)
2. She's soul (self-awareness, updated via `shepaw memory write --key soul`)
3. ShePaw CLI tool reference (teaches She available tools)
4. Current time (device real-time, injected dynamically)
5. Master's custom settings (from user detail page)
6. Strategy for learning about user
7. User profile snapshot (core + extended fields)
8. First meeting instruction (on first interaction only)
9. Session-end write instructions (immutable)

### **Session/Channel Structure**

#### **Channel Model** (`lib/models/channel.dart`)
```dart
class Channel {
  String id                              // UUID
  String name, type (dm/group/public)
  List<ChannelMember> members
  
  // Metadata
  String? description, avatar
  String createdBy
  int createdAt, updatedAt
  
  // Group-specific
  String? parentGroupId                  // For group sessions
  String? systemPrompt                   // Custom group prompt
  int? maxLoopRounds (default 50)
  String? mentionMode (adminOnly/allMembers)
  bool planningMode                      // Admin plan → User approve
  bool flowMode                          // ExecutionPlan-driven
  
  // Computed
  bool get isDM, isGroup, isPublic
  List<String> get agentIds
  String? get adminAgentId
  bool isAdmin(agentId)
}

class ChannelMember {
  String id, type (agent/user/role)
  String role (admin/member)
  int joinedAt
  String? groupBio                       // Channel-specific bio
}
```

#### **Message Structure** (`lib/models/message.dart`)
```dart
class Message {
  String id, channelId
  MessageFrom from (id, type, name)
  MessageFrom? to
  MessageType type (text/image/file/audio/system)
  String content
  int timestampMs
  String? replyTo
  Map<String, dynamic>? metadata         // file info, urls, etc.
}
```

### **Group Chat Orchestration Flow**

#### **1. Group Session Management** (`GroupSessionService`)
- Create group sessions for managing multi-agent conversations
- Sessions can be children of parent groups (for nested orchestration)
- Track session state and member participation

#### **2. Group Execution Pipeline** (`GroupOrchestrationService`)
**Path A: Standard Group Chat**
1. User sends message to group
2. Parse mentions (who to involve)
3. Build group system prompt + user message
4. Execute agents sequentially/parallel (depends on config)
5. Stream responses back to UI
6. Save messages to database

**Path B: Planning Mode** (`planningMode=true`)
1. Admin agent generates `ExecutionPlan` (structured JSON)
2. Plan includes stages, responsible agents, actions
3. PlanApprovalService shows plan to user for approval
4. User approves/rejects
5. FlowExecutor executes approved plan stage-by-stage

**Path C: Flow Mode** (`flowMode=true`)
1. Admin agent generates `ExecutionPlan` with detailed stages
2. FlowExecutor autonomously drives execution
3. Each stage's output feeds into next stage
4. System manages inter-stage data flow
5. Handles failures and retry logic

#### **3. Group Prompt Builder** (`GroupPromptBuilder`)
Constructs system prompt for group admin agent:
- Current members and their bios
- Group settings (loop rounds, mention mode)
- Task/context from user message
- Previous summary (if continuing conversation)

#### **4. Group Agent Executor** (`GroupAgentExecutor`)
Executes individual agent in group context:
- Manages ACP connection
- Streams responses back
- Handles interactive UI requests
- Executes tool calls with group context
- Detects task completion/errors

### **Direct Message (DM) Session Flow**

1. **User Message Sent**
   - Create Message record
   - Create/use ActiveTask
   - Establish ACP connection

2. **Agent Response**
   - Stream text chunks via `ui.textContent`
   - Handle UI interactions (forms, uploads, selections)
   - Execute tools if needed
   - On completion, save final message

3. **Session Persistence**
   - All messages saved to `messages` table
   - Keyed by `channel_id` (unique per agent/user pair)
   - Tool results stored separately for audit

4. **Session History**
   - SessionHistoryService loads prior messages
   - Agents can request more history via `ui.requestHistory`
   - Supports rollback to previous states

### **Agent Connection & Heartbeat**

#### **ACP Agent Connection** (`ACPAgentConnection`)
- WebSocket connection per agent
- Maintains request/response correlation
- Handles binary file transfers
- Implements timeout & retry logic
- Subscribes/unsubscribes from channels

#### **Health Checking** (`RemoteAgentService`)
- Periodic health checks on all agents
- Updates status in database
- Notifies UI of status changes
- Handles offline/error states

#### **Heartbeat Management** (`ACPServerService`)
- App serves WebSocket server on port 18790 (configurable)
- Receives inbound agent connections
- Validates token-based authentication
- Routes hub.* requests to handlers
- Manages file transfers from agents

---

## 7. Key Architecture Patterns

### **Singleton Services**
Most services use singleton pattern:
```dart
class MyService {
  static final MyService _instance = MyService._internal();
  factory MyService() => _instance;
  MyService._internal();
}
```

### **State Management**
- **Provider:** Global state (AppState, LocaleProvider, NotificationProvider)
- **GetX:** Controller-based state
- **StreamController:** Real-time updates (messages, status)

### **Database Access**
- `LocalDatabaseService` - SQLite operations
- `SheMemoryDbService`, `SheProfileDatabaseService` - She-specific data
- `AgentMemoryDbService` - Agent memory
- `ToolResultDatabaseService` - Tool results audit

### **UI-Business Logic Decoupling**
- `ActiveTask` callbacks detachable (UI can leave and reattach)
- Services survive navigation
- Callbacks set to null when UI unmounts
- Tasks continue running in background

### **ACP Protocol Handling**
- JSON-RPC 2.0 base format
- Bi-directional request/response via WebSocket
- Notification support (single-direction push)
- Binary file transfer protocol

### **Error Handling**
- Centralized `ErrorHandlerService`
- Logging via `LoggerService` (file-based persistence)
- User-facing error display in UI
- Permission denial handling

---

## 8. Important Configuration

### **SharedPreferences Keys** (`main.dart`)
```
kAcpServerPortKey               - ACP Server port (default 18790)
kAcpServerEnabledKey            - Enable/disable ACP Server
kAcpServerTokenKey              - Auth token for server
```

### **Database Versions**
- Current: 19 versions with upgrade migrations
- Migration history in `_onUpgrade()` method
- Field additions via `ALTER TABLE`

### **Localization**
- English & Chinese support
- Via `flutter_localizations`
- `l10n/app_localizations_*.dart` files

### **Security Features**
- Flutter Secure Storage for sensitive data
- Local authentication (biometric)
- Password hashing (crypto package)
- Encryption for stored data
- Permission-based access control
- Token-based agent authentication

---

## 9. Multi-Platform Support

- **iOS:** Native Swift integration
- **Android:** Native Kotlin integration, foreground service for background tasks
- **macOS:** Desktop multi-window support
- **Windows:** Desktop multi-window support, native notifications
- **Linux:** Desktop support
- **Web:** Browser-based support via sqflite_common_ffi_web

**Platform-Specific Handling:**
- `kIsWeb` checks for web-specific behavior
- `Platform.isXxx` checks for OS-specific code
- Foreground service for Android background tasks
- Desktop multi-window for macOS/Windows

---

## 10. Data Flow Diagram (High Level)

```
User Input
    ↓
[Chat Screen]
    ↓
[Chat Service] ← Manages ActiveTask, GroupActiveTask
    ↓
┌─────────────────────────────────────┐
│ DM Path      │     Group Path       │
│              │                      │
│ ACP Agent    │ Group Orchestration  │
│ Connection   │ Service              │
└─────────────────────────────────────┘
    ↓
[Agent Messaging Service]
    ↓
┌──────────────────────────────────────┐
│ UI Interactions │ Tool Execution     │
│ (forms, files)  │ (skills, CLI)      │
└──────────────────────────────────────┘
    ↓
[Local Database Service] ← SQLite persistence
    ↓
[UI Update] ← Stream updates back to chat screen
```

---

## 11. Launch & Initialization Sequence

1. **main()** → `runZonedGuarded` for error handling
2. Check if sub-window (desktop) vs main window
3. Initialize database factories (FFI on desktop/web)
4. **LoggerService** initialization (file logging)
5. **LocalDatabaseService** - Initialize SQLite
6. Initialize sample data (first launch)
7. Check remote agents health
8. **SheService** - Ensure She exists
9. **ACPServerService** - Start WebSocket server
10. **ChannelTunnelService** - Auto-start if configured
11. App lifecycle & notification services
12. **SkillRegistry** - Load markdown skills
13. **CliToolRegistry** - Load external CLI tools
14. **ModelRegistry** - Load tool model definitions
15. **TraceService** - Database cleanup
16. Run Flutter app with MultiProvider (state management)
17. Show SplashScreen → Login/Setup → Home

---

## Summary

**Paw** is a sophisticated agent orchestration platform built on Flutter with:
- Complex multi-agent group orchestration (planning, flow modes)
- Real-time messaging via WebSocket (ACP protocol)
- Persistent local database (SQLite with 11+ related tables)
- Built-in AI guardian agent (She) with memory & profile
- Flexible skill/tool system (markdown-based)
- Rich UI interaction framework (forms, selections, file uploads)
- Multi-platform support (mobile + desktop + web)
- Comprehensive security model (token auth, permissions, biometrics)
- Session management & conversation history
- Planning & execution workflows

All services are singleton-based, use Provider for state management, and implement detachable UI callbacks for background task resilience.


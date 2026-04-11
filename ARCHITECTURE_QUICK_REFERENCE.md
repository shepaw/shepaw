# Paw Architecture Quick Reference

## Quick Navigation

### 📁 Key Files to Know

| Component | Files |
|-----------|-------|
| **App Entry** | `lib/main.dart` (initialization & routing) |
| **Messaging** | `lib/services/chat_service.dart`, `lib/services/messaging/*` |
| **Group Orchestration** | `lib/services/group/*` (7 files) |
| **Database** | `lib/services/local_database_service.dart` (11+ tables) |
| **She Guardian** | `lib/services/she_service.dart` + 3 supporting DBs |
| **ACP Server** | `lib/services/acp_server_service.dart` (WebSocket) |
| **CLI Tools** | `lib/clis/shepaw/*` + `lib/services/skill_registry.dart` |
| **Screens** | `lib/screens/*` (44 screens) |
| **Models** | `lib/models/*` (31 models) |

---

## 🔧 Core Services (69 Total)

### Must-Know Services

```
ChatService
  ├─ ActiveTask (DM tasks)
  ├─ GroupActiveTask (group tasks)
  ├─ PlanApprovalService (planning mode)
  ├─ GroupOrchestrationService (group orchestration)
  ├─ FlowExecutor (plan-driven execution)
  ├─ SessionService (conversation sessions)
  ├─ HistoryService (message history)
  └─ AgentMessagingService (protocol handling)

LocalDatabaseService
  ├─ agents table (remote agents)
  ├─ channels table (conversations/groups)
  ├─ messages table (all messages)
  ├─ channel_members table (group membership)
  ├─ tasks table (A2A task tracking)
  ├─ tool_configs table (global tool config)
  └─ cli_command_configs table (CLI config)

SheService (Guardian Agent)
  ├─ SheMemoryDbService (soul, self-notes, memory)
  ├─ SheProfileDatabaseService (user profile)
  ├─ AgentMemoryDbService (agent memories)
  └─ CognitionService (user cognition)

ACPServerService (WebSocket Server)
  ├─ Inbound agent connections
  ├─ Hub request handlers
  ├─ File transfer protocol
  └─ Token-based auth

RemoteAgentService (Agent Management)
  ├─ Health checks
  ├─ Connection lifecycle
  └─ Status updates
```

---

## 📊 Database Schema (Simplified)

```
┌──────────────────────────────────────────┐
│        MAIN DATABASE: shepaw.db          │
├──────────────────────────────────────────┤
│
│  agents ──────────────┐
│     ↓                 │
│  agent_cards          │ (metadata, capabilities)
│     ↓                 │
│  tasks (A2A)          │
│
│  channels ────────┐
│     ↓             │
│  channel_members──┼──→ agents
│     ↓             │
│  messages ────────┘
│
│  tool_configs
│  cli_command_configs
│
├──────────────────────────────────────────┤
│    SEPARATE DATABASES (She-specific)     │
├──────────────────────────────────────────┤
│  she_memory.db (soul, notes, memory)
│  she_profile.db (user profile fields)
│  agent_memory.db (per-agent memory)
│  minds.db (cognition, profiles)
│  tool_results.db (tool execution audit)
│  trace.db (inference traces, analytics)
└──────────────────────────────────────────┘
```

---

## 🌐 ACP Protocol (WebSocket JSON-RPC 2.0)

### Flows

```
┌─ App Sends ──────────────────────────────────┐
│  auth.authenticate                           │
│  agent.chat (user message)                   │
│  agent.cancelTask                            │
│  agent.submitResponse (UI interaction)       │
│  agent.rollback                              │
│  ping                                        │
└──────────────────────────────────────────────┘
                    ↕ WebSocket
┌─ Agent Sends (Notifications/Requests) ──────┐
│                                              │
│ ┌─ UI Events ────────────────────────────┐  │
│ │ ui.textContent (stream)                │  │
│ │ ui.actionConfirmation                  │  │
│ │ ui.singleSelect / ui.multiSelect       │  │
│ │ ui.form                                │  │
│ │ ui.fileUpload                          │  │
│ │ ui.fileMessage (file/image)            │  │
│ │ ui.messageMetadata                     │  │
│ │ ui.requestHistory (more context)       │  │
│ └────────────────────────────────────────┘  │
│                                              │
│ ┌─ Task Lifecycle ───────────────────────┐  │
│ │ task.started                           │  │
│ │ task.completed                         │  │
│ │ task.error                             │  │
│ └────────────────────────────────────────┘  │
│                                              │
│ ┌─ Hub Requests (Get App Data) ──────────┐  │
│ │ hub.getSessions                        │  │
│ │ hub.getSessionMessages                 │  │
│ │ hub.getAgentList                       │  │
│ │ hub.getHubInfo                         │  │
│ │ hub.initiateChat (agent → app)         │  │
│ │ hub.subscribeChannel                   │  │
│ │ hub.getAttachmentContent               │  │
│ │ (+ 4 more methods)                     │  │
│ └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

---

## 👥 Agent Types & Capabilities

### RemoteAgent (in database)

```dart
RemoteAgent {
  id                    // UUID
  name                  // Display name
  status                // online/offline/error
  capabilities          // Feature list
  metadata {
    is_she                                    // Boolean
    enabled_os_tools      // [list]           // System tool access
    enabled_skills        // [list]           // Markdown skills
    enabled_tool_models   // [list]           // Vision/audio models
    enabled_cli_commands  // [list]           // CLI tool whitelist
    model_routing         // {modality→model} // Multi-modal routing
    prompt_stack_config   // {sections}       // Prompt composition
    allow_external_access // Boolean          // Public tunnel
    channel_config        // {...}            // Tunnel settings
  }
}
```

### She (Special Built-in Agent)

- **ID:** `she-builtin-agent-001`
- **Status:** Always online & pinned
- **Role:** Guardian with personal growth
- **Memory:** Separate DB for soul + self-notes
- **Profile:** Dedicated user profile (15 fields)
- **Learning:** Proactively learns about user via prompts

---

## 📱 Session/Channel Types

| Type | Use Case | Members | Parent |
|------|----------|---------|--------|
| **DM** | 1-on-1 with agent | 2 | — |
| **Group** | Multi-agent collaboration | 2+ agents | — |
| **Group Session** | Nested execution | Subset | Group |
| **Public** | Broadcast? | Many | — |

### Group Modes

| Mode | Admin | User | Flow |
|------|-------|------|------|
| **Standard** | Executes agents | Reads responses | Real-time |
| **Planning** | Generates plan | Approves/rejects | Then execute |
| **Flow** | Creates FlowPlan | Auto-executes | Stage-by-stage |

---

## 🚀 Execution Paths

### 1️⃣ Direct Message (DM)

```
User Message
    ↓
Create ActiveTask
    ↓
ACP Connection → Agent
    ↓
Stream: ui.textContent chunks
Handle: UI interactions (forms, uploads)
Execute: Tools as needed
    ↓
task.completed
Save message + tool results
    ↓
Update UI
```

### 2️⃣ Group Chat (Standard)

```
User Message → Group
    ↓
GroupOrchestrationService
    ↓
Parse mentions / build prompt
    ↓
For each agent:
  ├─ Create GroupActiveTask
  ├─ Send via ACP
  ├─ Stream responses
  ├─ Handle interactions
  └─ Save message
    ↓
Optional: summarize & loop
```

### 3️⃣ Group Chat (Planning Mode)

```
User Message → Group (planning_mode=true)
    ↓
Admin Agent generates ExecutionPlan (JSON)
    ↓
PlanApprovalService
    ↓
Show plan to user (UI dialog)
    ↓
User [Approve] / [Reject]
    ↓
If approved:
  └─ Execute each stage
If rejected:
  └─ Return to admin for revision
```

### 4️⃣ Group Chat (Flow Mode)

```
User Message → Group (flow_mode=true)
    ↓
Admin Agent generates ExecutionPlan with stages
    ↓
FlowExecutor
    ↓
For each stage:
  ├─ Determine responsible agent(s)
  ├─ Execute with prior stage output
  ├─ Collect results
  ├─ Feed to next stage
  └─ Update task board
    ↓
All stages complete
    ↓
Done
```

---

## 🛠️ Extending the System

### Add a Skill (Markdown-based)

```bash
~/Documents/Paw/skills/
├── my_skill/
│   ├── SKILL.md (with front matter: name, description)
│   ├── helper_script.py
│   └── data.json
```

SkillRegistry auto-loads on app startup.

### Add an OS Tool

Define in database:
```
tool_configs {
  tool_name: "system_shutdown"
  parameter_overrides: {...}
  enabled: 1
  she_exclusive: 0
}
```

### Add a CLI Command

Define in database:
```
cli_command_configs {
  command_id: "shepaw agents list"
  global_enabled: 1
  she_only: 0
}
```

### Add a Model (Vision/Audio)

Use ModelRegistry:
```dart
ModelRegistry.instance.getDefinition(toolName)
// Returns ModelDefinition with supported types
```

---

## 🔐 Security Model

| Layer | Method |
|-------|--------|
| **App ↔ Device** | Biometric + Password (flutter_secure_storage) |
| **App ↔ Agent** | Token-based auth (UUID per agent) |
| **Agent ↔ Hub** | HMAC signature (if enabled) |
| **Data at Rest** | Encryption (crypto package) |
| **Permissions** | ACP permission requests (agent asks, user approves) |

---

## 📈 State Management

### Global State (Provider)

```dart
AppState              // Main app state
LocaleProvider        // Language selection (en/zh)
NotificationProvider  // Notification settings
```

### Local State (StreamControllers)

```dart
ChatService:
  _messageControllers[channelId]    // Message stream per channel
  _requestController                // ACP server requests
```

### Singleton Services

All major services (ChatService, LocalDatabaseService, SheService, etc.) are singletons, initialized in main().

---

## 🔄 UI Lifecycle & Background Persistence

### Detachable Tasks

When user leaves chat screen:
1. ActiveTask/GroupActiveTask remain alive
2. UI callbacks set to null (`detachUI()`)
3. Task continues in background
4. If user returns, reattach callbacks
5. UI receives buffered content

### Navigation

```
SplashScreen
    ↓
(Check password set?)
    ↓
PasswordSetupScreen  OR  LoginScreen
    ↓
AdaptiveHomeScreen (responsive layout)
    ↓
ChatScreen (selected channel)
    ↓
Settings, Agent Detail, etc. (sub-screens)
```

---

## 📝 Logging & Debugging

- **Logger:** `LoggerService` (file-based, persistent)
- **Traces:** `TraceService` (inference traces in DB)
- **Screen:** `LogViewerScreen` (view logs in-app)
- **Export:** `DataExportImportService` (backup/restore)

---

## 🏆 Key Patterns

| Pattern | Usage | Example |
|---------|-------|---------|
| **Singleton** | Services | `ChatService.instance` |
| **Factory** | Models | `RemoteAgent.fromJson()` |
| **Stream** | Real-time updates | `messageControllers[id].stream` |
| **Callback Injection** | Detachable UI | `activeTask.onStreamChunk = ...` |
| **Service Locator** | Dependency injection | `LocalDatabaseService()` |
| **Observer** | Status changes | `onAgentDisconnected` callback |

---

## 🚦 Common Tasks

### Send a message to an agent
```dart
chatService.sendMessage(
  channelId: 'dm_xyz',
  userId: 'user_001',
  userName: 'John',
  content: 'Hello!',
  agent: remoteAgent,
);
```

### Create a group
```dart
channel = Channel(
  id: uuid.v4(),
  name: 'Team Meeting',
  type: 'group',
  members: [agent1, agent2, agent3],
  planningMode: false,
  flowMode: false,
);
await db.createChannel(channel);
```

### Enable a skill for an agent
```dart
await db.updateRemoteAgent(agent.copyWith(
  metadata: {...agent.metadata, 'enabled_skills': ['code_review', 'summarize']}
));
```

### Query user profile
```dart
final name = await cognitionService.getProfileField('name');
```

### Write to She's soul
```dart
await sheMemoryDb.setSheMemory('soul', 'I am She, ...custom text...');
```

---

## 📞 Support Quick Links

- **ACP Protocol:** `lib/models/acp_protocol.dart`
- **Task Models:** `lib/services/task/task_models.dart`
- **Database Schema:** `lib/services/local_database_service.dart` (_onCreate method)
- **Group Orchestration:** `lib/services/group/group_orchestration_service.dart`
- **Chat Logic:** `lib/services/chat_service.dart` (1100+ lines)

---

**Last Updated:** April 2026
**Schema Version:** 19
**Platforms:** iOS, Android, macOS, Windows, Linux, Web

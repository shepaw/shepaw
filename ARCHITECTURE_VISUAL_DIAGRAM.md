# Paw Architecture - Visual Diagrams

## High-Level System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         FLUTTER APPLICATION                         │
│                    (iOS/Android/macOS/Windows/Web)                 │
├─────────────────────────────────────────────────────────────────────┤
│
│  ┌──────────────────────┐  ┌──────────────────────┐
│  │   Screens (44)       │  │   State Management   │
│  │                      │  │                      │
│  │ • ChatScreen         │  │ • Provider (global)  │
│  │ • HomeScreen         │  │ • GetX (controller)  │
│  │ • AgentListScreen    │  │ • StreamControllers  │
│  │ • SettingsScreen     │  │   (per-channel)      │
│  │ • etc...             │  │                      │
│  └──────────────────────┘  └──────────────────────┘
│           ↓                           ↓
│  ┌──────────────────────────────────────────────┐
│  │          ChatService (Singleton)             │
│  ├──────────────────────────────────────────────┤
│  │ • Manages ActiveTask (DM)                    │
│  │ • Manages GroupActiveTask (groups)           │
│  │ • Manages GroupOrchestrationService          │
│  │ • Manages FlowExecutor (plan execution)      │
│  │ • Manages SessionService (DM sessions)       │
│  │ • Manages HistoryService (message history)   │
│  │ • ACP connection pool per agent              │
│  │ • Message streaming & caching                │
│  └──────────────────────────────────────────────┘
│           ↓
├─────────────────────────────────────────────────────────────────────┤
│                      CORE SERVICES LAYER                            │
├─────────────────────────────────────────────────────────────────────┤
│
│  ┌──────────────────────────┐  ┌──────────────────────────┐
│  │  Local Database Service  │  │  ACP Server Service      │
│  │  (SQLite 19 versions)    │  │  (WebSocket Server)      │
│  │                          │  │                          │
│  │ Tables:                  │  │ • Inbound connections    │
│  │ • agents                 │  │ • Hub request handlers   │
│  │ • channels               │  │ • File transfer          │
│  │ • messages               │  │ • Token auth             │
│  │ • channel_members        │  │                          │
│  │ • tasks (A2A)            │  │ ┌────────────────┐       │
│  │ • tool_configs           │  │ │ Runs on        │       │
│  │ • cli_command_configs    │  │ │ localhost:18790│       │
│  │                          │  │ └────────────────┘       │
│  └──────────────────────────┘  └──────────────────────────┘
│           ↓                              ↑
│  ┌──────────────────────────────────────────────────────┐
│  │         RemoteAgentService & ACP Connection          │
│  │                                                      │
│  │ • Health checks (periodic)                          │
│  │ • Connection lifecycle management                   │
│  │ • Status updates (online/offline/error)             │
│  │ • Agent messaging (AgentMessagingService)           │
│  │ • Protocol routing (ACP/custom)                     │
│  └──────────────────────────────────────────────────────┘
│
└─────────────────────────────────────────────────────────────────────┘
        ↓                              ↑
        │ WebSocket (JSON-RPC 2.0)     │
        │                              │
        ↓                              ↑
┌─────────────────────────────────────────────────────────────────────┐
│                      REMOTE AGENTS (External)                       │
│                                                                     │
│  Agent1 ←──────────→ App  ←──────────→ Agent2                      │
│  (LLM)              (Paw)              (LLM)                        │
│                                        Agent3                      │
│                                        (LLM)                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## She (Guardian Agent) Architecture

```
┌────────────────────────────────────────────────────────────┐
│                    SheService (Singleton)                  │
│                                                            │
│ • ensureSheExists() - Initialize She on first launch      │
│ • User profile management                                 │
│ • Memory operations                                       │
│ • Cognition integration                                   │
└────────────────────────────────────────────────────────────┘
           ↓
        ┌──────────────────────────────────────────────┐
        │  Three Dedicated Databases for She           │
        └──────────────────────────────────────────────┘
           ↓
    ┌──────────────┬──────────────┬──────────────┐
    ↓              ↓              ↓              ↓
┌─────────┐  ┌──────────┐  ┌───────────┐  ┌──────────┐
│she_     │  │she_      │  │agent_     │  │cognition │
│memory.db│  │profile.db│  │memory.db  │  │_service  │
│         │  │          │  │           │  │          │
│ soul    │  │ core:    │  │per-agent  │  │user      │
│ self_   │  │ • name   │  │long-term  │  │profile   │
│notes    │  │ • age    │  │memory     │  │          │
│memory   │  │ • gender │  │storage    │  │ 15 fields│
│heartbeat│  │ • city   │  │           │  │          │
│         │  │          │  │           │  │          │
│         │  │extended: │  │           │  │          │
│         │  │ • goals  │  │           │  │          │
│         │  │ • health │  │           │  │          │
│         │  │ • notes  │  │           │  │          │
│         │  │ (11 more)│  │           │  │          │
└─────────┘  └──────────┘  └───────────┘  └──────────┘
```

### She's Prompt Stack (Per Conversation)

```
┌────────────────────────────────────────────────────┐
│  Layer 1: She Core Identity (Immutable)            │
│  "I am She, your dedicated guardian..."            │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 2: Soul (Mutable)                           │
│  from she_memory.db['soul']                        │
│  "I am gentle and principled..."                   │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 3: ShePaw CLI Tool Reference                │
│  "You have access to shepaw command:"              │
│  • shepaw agents list                              │
│  • shepaw memory write ...                         │
│  • shepaw skills list                              │
│  • etc.                                            │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 4: Current Time                             │
│  Injected dynamically (real-time)                  │
│  "Current time: 2026-04-11 15:30:45"              │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 5: Master's Custom Settings                 │
│  from agent metadata['system_prompt']              │
│  User-provided customization                       │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 6: Learning Strategy                        │
│  "Ask about master's interests, goals..."          │
│  Prompts She to proactively learn                  │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 7: User Profile Snapshot (Layered)          │
│  • Core layer (always): name, age, gender, etc.   │
│  • Extended layer (if filled): interests, goals   │
│  • Activity layer: recent interactions            │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 8: First Meeting Instruction                │
│  (Only if user profile is empty)                   │
│  "Welcome to our first meeting..."                 │
└────────────────────────────────────────────────────┘
           ↓
┌────────────────────────────────────────────────────┐
│  Layer 9: Session-End Instructions                 │
│  (Immutable)                                       │
│  "Remember what you learned today..."              │
└────────────────────────────────────────────────────┘
```

---

## Group Chat Orchestration Flows

### Flow 1: Standard Group Execution

```
User sends message to group
        ↓
[GroupOrchestrationService]
        ↓
    ┌─────────────────────────────────────┐
    │ 1. Parse mentions in message        │
    │    (which agents to involve?)        │
    ├─────────────────────────────────────┤
    │ 2. Build group system prompt         │
    │    (members, bio, settings)          │
    ├─────────────────────────────────────┤
    │ 3. For each mentioned agent:         │
    │    ├─ Create GroupActiveTask         │
    │    ├─ Send ACP request               │
    │    ├─ Stream ui.textContent          │
    │    ├─ Handle interactions (forms,    │
    │    │   file uploads, selections)     │
    │    └─ Execute tools if needed        │
    ├─────────────────────────────────────┤
    │ 4. Save all messages to DB           │
    ├─────────────────────────────────────┤
    │ 5. Optional: Summarize & loop        │
    │    (for max_loop_rounds)             │
    └─────────────────────────────────────┘
        ↓
   Done ✓


```

### Flow 2: Planning Mode (Admin Approval)

```
User sends message to group
(planning_mode = true)
        ↓
[GroupOrchestrationService]
        ↓
Admin Agent processes request
        ↓
Generate ExecutionPlan (JSON):
{
  "stages": [
    {
      "id": "stage_1",
      "name": "Requirements Analysis",
      "responsible_agent": "agent_001",
      "actions": [...],
      "expected_output": "..."
    },
    {
      "id": "stage_2",
      "name": "Design Phase",
      "responsible_agent": "agent_002",
      "depends_on": ["stage_1"],
      "actions": [...],
      ...
    },
    ...
  ]
}
        ↓
[PlanApprovalService]
        ↓
Show plan to user:
┌────────────────────────────┐
│    Review Execution Plan   │
├────────────────────────────┤
│ ☐ Stage 1: Analysis        │
│ ☐ Stage 2: Design          │
│ ☐ Stage 3: Implementation  │
├────────────────────────────┤
│  [Approve]  [Reject/Revise]│
└────────────────────────────┘
        ↓
    If [Approve]:
        ↓
    [FlowExecutor] executes stages
        ↓
    Stage 1 → Stage 2 → Stage 3
    (output flows to next stage)
        ↓
    Done ✓
    
    If [Reject/Revise]:
        ↓
    Send feedback to admin
        ↓
    Admin regenerates plan
        ↓
    Show updated plan to user
        ↓
    Loop back to user approval
```

### Flow 3: Flow Mode (Autonomous Execution)

```
User sends message to group
(flow_mode = true)
        ↓
Admin Agent generates detailed ExecutionPlan
(with all stage outputs pre-defined as JSON)
        ↓
[FlowExecutor] takes over autonomously
        ↓
    For each Stage in Plan:
    ┌─────────────────────────────┐
    │ 1. Determine agent(s)       │
    │ 2. Pass prior outputs       │
    │ 3. Execute agent            │
    │ 4. Collect results          │
    │ 5. Update task board UI     │
    │ 6. Feed to next stage       │
    │ 7. Handle errors/retries    │
    └─────────────────────────────┘
        ↓
    Stage 1 completes
        ↓
    Stage 2 completes
        ↓
    Stage 3 completes
        ↓
    All stages done
        ↓
    Done ✓ (No user approval needed)
```

---

## Message Flow Diagram (DM)

```
┌─────────┐
│ User    │
│ Input   │
└────┬────┘
     │
     ↓
┌──────────────────┐
│ Chat Screen      │
│ (UI Component)   │
└────┬─────────────┘
     │
     ↓
┌────────────────────────────┐
│ ChatService.sendMessage()  │
└────┬───────────────────────┘
     │
     ├─→ Create Message record (pending)
     │
     ├─→ Create/Retrieve ActiveTask
     │
     ├─→ Establish ACP Connection (or reuse)
     │
     ├─→ Send agent.chat request (JSON-RPC)
     │
     ↓
┌──────────────────────────────────┐
│ Remote Agent (External)          │
│                                  │
│ • Process request                │
│ • Generate response              │
│ • Stream chunks via WebSocket    │
│ • Send ui.textContent events    │
│ • Execute tools if needed        │
└──────────────────────────────────┘
     │
     ↓ WebSocket events (JSON-RPC notifications)
┌──────────────────────────────────┐
│ ACPAgentConnection listens       │
│ (on app side)                    │
└──────────────────────────────────┘
     │
     ├─→ ui.textContent
     │   └─→ onStreamChunk callback
     │       └─→ ActiveTask accumulates text
     │           └─→ UI updates in real-time
     │
     ├─→ ui.actionConfirmation
     │   └─→ onActionConfirmation callback
     │
     ├─→ ui.singleSelect
     │   └─→ onSingleSelect callback
     │       └─→ User picks option
     │           └─→ agent.submitResponse
     │
     ├─→ ui.form
     │   └─→ onForm callback
     │       └─→ User fills form
     │           └─→ agent.submitResponse
     │
     ├─→ ui.fileUpload
     │   └─→ onFileUpload callback
     │
     ├─→ task.completed
     │   └─→ ActiveTask.isComplete = true
     │       └─→ Finalize message
     │           └─→ Save to DB
     │               └─→ dbSaveCompleter.complete()
     │
     ↓
┌──────────────────────────────────┐
│ Message saved to DB              │
│ (messages table)                 │
└──────────────────────────────────┘
     │
     ↓
┌──────────────────────────────────┐
│ UI refreshes                     │
│ (StreamController notification)  │
└──────────────────────────────────┘
     │
     ↓
┌──────────────────────────────────┐
│ Chat Screen shows final message  │
└──────────────────────────────────┘
```

---

## Database Relationship Diagram

```
┌──────────────────────────────────────────────────────────┐
│                    Main Database                         │
│                    (shepaw.db)                           │
└──────────────────────────────────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ↓               ↓               ↓
    ┌────────┐    ┌────────────┐   ┌──────────────┐
    │ agents │    │  channels  │   │  messages    │
    ├────────┤    ├────────────┤   ├──────────────┤
    │ id (PK)│    │ id (PK)    │   │ id (PK)      │
    │ name   │    │ name       │   │ channel_id   │──┐
    │ status │    │ type       │   │ sender_id    │  │
    │ token  │    │ members    │   │ content      │  │
    │ meta   │    │ created_by │   │ message_type │  │
    └────────┘    └────────────┘   │ created_at   │  │
        ↑              │            └──────────────┘  │
        │              │                              │
        │              ↓                              │
        │         ┌──────────────┐                    │
        │         │channel_      │                    │
        │         │members       │                    │
        │         ├──────────────┤                    │
        │         │channel_id    │────────────────────┘
        └─────────┤agent_id      │
                  │role          │
                  │joined_at     │
                  └──────────────┘

    ┌────────────────────────────────┐
    │  tasks (A2A Protocol)          │
    ├────────────────────────────────┤
    │ task_id                        │
    │ agent_id ──────────────→ agents│
    │ state (pending/running/done)   │
    │ request_data                   │
    │ response_data                  │
    └────────────────────────────────┘

    ┌────────────────────────────────┐
    │  tool_configs                  │
    ├────────────────────────────────┤
    │ tool_name (PK)                 │
    │ enabled                        │
    │ parameter_overrides (JSON)     │
    │ she_exclusive                  │
    └────────────────────────────────┘

    ┌────────────────────────────────┐
    │  cli_command_configs           │
    ├────────────────────────────────┤
    │ command_id (PK)                │
    │ global_enabled                 │
    │ she_only                       │
    └────────────────────────────────┘
```

---

## ACP Protocol Message Exchange

```
                    WebSocket (Persistent)
                   /                      \
                  /                        \
        [App/Paw]                    [Remote Agent]
            │                             │
            │ 1. auth.authenticate       │
            ├────────────────────────────→│
            │                             │
            │ 2. authenticate response   │
            │←────────────────────────────┤
            │                             │
            │ 3. agent.chat             │
            │ (user message)             │
            ├────────────────────────────→│
            │                             │
            │ 4. ui.textContent         │
            │ (streamed chunks)          │
            │←────────────────────────────┤
            │                             │
            │ 5. ui.textContent         │
            │ (more chunks)              │
            │←────────────────────────────┤
            │                             │
            │ 6. ui.singleSelect        │
            │ (user must choose)         │
            │←────────────────────────────┤
            │                             │
            │ 7. agent.submitResponse    │
            │ (user's choice)            │
            ├────────────────────────────→│
            │                             │
            │ 8. ui.textContent         │
            │ (final response)           │
            │←────────────────────────────┤
            │                             │
            │ 9. task.completed         │
            │←────────────────────────────┤
            │                             │
            │ 10. ping (heartbeat)      │
            ├────────────────────────────→│
            │                             │
            │ 11. (pong response)        │
            │←────────────────────────────┤
            │                             │

All messages use JSON-RPC 2.0 format:
{
  "jsonrpc": "2.0",
  "method": "method.name",
  "params": {...},
  "id": 123
}
```

---

## Service Initialization Order (main.dart)

```
1. WidgetsFlutterBinding.ensureInitialized()
   └─ Flutter framework initialization
   
2. Database factory setup (FFI for desktop/web)
   └─ sqflite_common_ffi initialization
   
3. LoggerService.initialize()
   └─ File-based logging setup
   
4. LocalDatabaseService initialization
   └─ SQLite connection & schema creation
   
5. LocalApiService initialization
   └─ Sample data loading
   
6. RemoteAgentService.checkAllAgentsHealth()
   └─ Periodic health checks
   
7. SheService.ensureSheExists()
   └─ Create She if first launch
   
8. ACPServerService initialization & start()
   └─ WebSocket server on port 18790
   
9. ChannelTunnelService auto-initialization
   └─ Start if configured in agent metadata
   
10. AppLifecycleService.init()
    └─ App lifecycle hooks
    
11. NotificationService.init()
    └─ Local notification setup
    
12. UpdateNotificationService.init()
    └─ App update checks
    
13. ForegroundTaskService.init()
    └─ Android foreground service
    
14. SkillRegistry.initialize()
    └─ Load markdown skills from filesystem
    
15. CliToolRegistry.initialize()
    └─ Load external CLI tools
    
16. ModelRegistry.initialize()
    └─ Load tool model definitions
    
17. TraceService.cleanup()
    └─ Database retention cleanup
    
18. runApp() → MyApp
    └─ Flutter UI initialization
    
19. SplashScreen → LoginScreen/PasswordSetupScreen
    └─ Authentication flow
    
20. AdaptiveHomeScreen (responsive layout)
    └─ Main app UI
```

---

## State Persistence & Background Task Lifecycle

```
User in Chat Screen
        │
        ├─→ ActiveTask created
        │   ├─ Task data in memory
        │   ├─ ACP connection alive
        │   └─ UI callbacks active
        │
User navigates away (back button)
        │
        ├─→ detachUI() called
        │   ├─ UI callbacks set to null
        │   ├─ Message accumulation continues
        │   ├─ ACP connection stays alive
        │   └─ Task runs in background
        │
        ↓
Background execution:
    • Task continues receiving data
    • onStreamChunk buffered
    • Tools executed
    • Database updates queued
        │
User navigates back to same channel
        │
        ├─→ Reattach callbacks
        │   ├─ Set onStreamChunk callback again
        │   ├─ UI receives buffered content
        │   ├─ dbSaveCompleter fires when done
        │   └─ Messages saved to DB
        │
Task completes
        │
        ├─→ dbSaveCompleter.complete()
        ├─→ Final message saved
        ├─→ onTaskFinished() called
        ├─→ ActiveTask removed from registry
        └─→ ACP connection closed
```

---

## CLI Tool Execution (from She/Agents)

```
┌────────────────────────┐
│  ShePaw CLI Tool Call  │
│  (from agent action)   │
└──────────┬─────────────┘
           │
           ↓
┌────────────────────────────────────────┐
│  CLI Tool Name:                        │
│  "shepaw agents list"                  │
│  "shepaw memory write --key soul ..."  │
│  "shepaw chat messages <channel_id>"   │
│  "shepaw skills list"                  │
│  etc.                                  │
└──────────┬─────────────────────────────┘
           │
           ↓
┌────────────────────────────────────────┐
│  ShepawCLI.execute(command)            │
│                                        │
│  Parses namespace & command:           │
│  "agents" → AgentsNamespace            │
│  "list" → ListCommand                  │
│                                        │
│  "memory" → MemoryNamespace            │
│  "write" → WriteCommand                │
└──────────┬─────────────────────────────┘
           │
           ├─→ AgentMemoryDbService
           │   └─→ she_memory.db
           │
           ├─→ LocalDatabaseService
           │   └─→ shepaw.db (agents, messages)
           │
           ├─→ SkillRegistry
           │   └─→ Loaded .md skills
           │
           ├─→ CliToolRegistry
           │   └─→ External CLI tools
           │
           ├─→ ChatService
           │   └─→ Channel/message operations
           │
           └─→ CognitionService
               └─→ user_profile.db
           │
           ↓
┌────────────────────────────────────────┐
│  Return Result (JSON)                  │
│  {                                     │
│    "status": "success",                │
│    "data": [...]                       │
│  }                                     │
└────────────────────────────────────────┘
           │
           ↓
┌────────────────────────────────────────┐
│  Include in Agent Response             │
│  (tool call result)                    │
└────────────────────────────────────────┘
```

---

## Multi-Platform Architecture

```
┌────────────────────────────────────────────────────┐
│             Flutter Core (lib/)                    │
│         Models, Services, Screens, Utils            │
└────────────────────────────────────────────────────┘
                       ↓
        ┌──────────────┼──────────────┐
        ↓              ↓              ↓
   ┌─────────┐   ┌─────────┐   ┌─────────────┐
   │ Android │   │ iOS     │   │ macOS/Win/  │
   │ Native  │   │ Native  │   │ Linux/Web   │
   ├─────────┤   ├─────────┤   ├─────────────┤
   │ Kotlin  │   │ Swift   │   │ FFI + SDK   │
   │ Services│   │ Services│   │ Services    │
   │ (FG)    │   │ (local) │   │ (native)    │
   └─────────┘   └─────────┘   └─────────────┘

FG = Foreground Service (Android background task)

Database Initialization:
  └─ iOS/Android: sqflite (native SQLite)
  └─ macOS/Windows/Linux: sqflite_common_ffi
  └─ Web: sqflite_common_ffi_web
```

---

**Diagrams Generated:** April 2026
**Architecture Version:** 1.0

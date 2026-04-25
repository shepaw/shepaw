# ShePaw Quick Start Guide for Developers

## Where to Start

### 1. **Entry Points**
- **App Entry**: `lib/main.dart` (21KB)
  - Initializes services, loads database, sets up state management
  - Detects if running as sub-window (desktop multi-window support)

- **Sub-Window Entry**: `lib/sub_window_app.dart` (2.3KB)
  - Lightweight entry for desktop multi-window app instances

### 2. **Core Message Flow**
1. User enters message in `lib/widgets/chat/chat_input_area.dart`
2. Calls `ChatService.sendMessage()` → `lib/services/chat_service.dart` (45KB)
3. Saves to database via `LocalDatabaseService.createMessage()`
4. Routes to appropriate agent handler:
   - **Remote Agent**: `ACPAgentConnection.sendRequest()` (WebSocket)
   - **Local LLM**: `LocalLLMAgentService.chat()` (HTTP SSE)
   - **Group**: `GroupOrchestrationService.sendMessageToGroup()`
5. Streams response back to UI
6. `ChatScreen` renders via `message_bubble.dart` and related widgets

---

## Key Services (Must Understand)

### 1. **ChatService** (`lib/services/chat_service.dart`)
The central hub for all messaging operations.

**Key Methods:**
```dart
// Send to single agent
Future<void> sendMessage({
  required String channelId,
  required String content,
  String? agentId,
  List<String>? attachmentIds,
});

// Send to group (multi-agent)
Future<void> sendMessageToGroup({
  required String channelId,
  required String content,
  required List<String> agentIds,
  String? adminAgentId,
  bool planningMode = false,
  bool flowMode = false,
});

// Load messages
Future<List<Message>> loadChannelMessages(String channelId, {int limit = 100});

// Stream updates
Stream<List<Message>> watchMessages(String channelId);
```

**Database**: SQLite via `LocalDatabaseService`

---

### 2. **LocalLLMAgentService** (`lib/services/local_llm_agent_service.dart`)
Direct LLM API integration (no remote endpoint needed).

**Supported Providers:**
- OpenAI, Claude, Gemini, DeepSeek, Qwen, GLM, Kimi, Grok, Ollama

**Key Method:**
```dart
Stream<LLMStreamEvent> chat({
  required RemoteAgent agent,
  required String message,
  List<Map<String, dynamic>>? history,
  bool enableUITools = true,
  String? systemPromptOverride,
  List<AttachmentData>? attachments,
});
```

**Returns:**
- `LLMTextEvent` - Text tokens
- `LLMToolCallEvent` - Tool invocations
- `LLMDoneEvent` - Completion with stop_reason

---

### 3. **ACPAgentConnection** (`lib/services/acp_agent_connection.dart`)
WebSocket JSON-RPC 2.0 client for remote agents.

**Protocol:**
- Bidirectional communication over WebSocket
- Token-based authentication
- Request/response pattern with unique IDs

**Key Methods:**
```dart
// Connect to remote agent
Future<bool> connect(String wsUrl, String token);

// Send message (request)
Future<ACPResponse> sendMessage(String message, {TaskCallbacks callbacks});

// Cancel task
Future<ACPResponse> cancelTask(String taskId);

// Disconnect
Future<void> disconnect();
```

**Handler for Hub Requests:**
- File operations, tool calls, system queries delegated to `ACPHubHandlers`

---

### 4. **LocalDatabaseService** (`lib/services/local_database_service.dart`)
SQLite wrapper for all persistent data.

**Key Tables:**
- `agents` - Remote agent definitions
- `channels` - Conversations
- `messages` - Chat messages
- `attachments` - Files
- `inference_log` - Token usage
- `trace_log` - Request tracing

**Key Methods:**
```dart
// Message operations
Future<void> createMessage({required String id, required String channelId, ...});
Future<List<Message>> getMessages(String channelId, {int limit = 100});

// Agent operations
Future<RemoteAgent?> getAgent(String id);
Future<List<RemoteAgent>> getAllAgents();

// Channel operations
Future<void> createChannel({required String id, required String name, ...});
```

---

### 5. **RemoteAgentService** (`lib/services/remote_agent_service.dart`)
Agent lifecycle management (create, update, delete, auth).

**Key Methods:**
```dart
// Create new agent
Future<RemoteAgent> createAgent({
  required String name,
  required ProtocolType protocol,
  required ConnectionType connectionType,
  String endpoint = '',
  String avatar = '🤖',
  Map<String, dynamic> metadata = const {},
});

// Token management
Future<String> generateToken();
Future<String> regenerateToken(String agentId);
```

**Agent Types:**
1. **Remote Agent (ACP)**: WebSocket endpoint, token auth
2. **Local LLM Agent**: API key + LLM provider config

---

### 6. **GroupOrchestrationService** (`lib/services/group/group_orchestration_service.dart`)
Multi-agent coordination (82KB - complex).

**Three Modes:**
1. **Standard**: Admin rounds (sequential agents, up to 50 rounds)
2. **Planning**: Agent generates JSON task plan, user approves
3. **Flow**: Auto-execute multi-stage workflow with P/R/S/A controls

**Key Method:**
```dart
Future<void> sendMessageToGroup({
  required String channelId,
  required String content,
  required String userId,
  required List<String> agentIds,
  String? adminAgentId,
  bool planningMode = false,
  bool flowMode = false,
  void Function(String agentId, String chunk)? onStreamChunk,
  void Function(String agentId)? onAgentStart,
  void Function(String agentId, bool skipped)? onAgentDone,
});
```

---

## Configuration & Registry Systems

### 1. **Skill Registry** (`lib/services/skill_registry.dart`)
Markdown-based instruction sets loaded into system prompts.

**Location**: `~/shepaw/skills/`

**Structure**:
```
skills/
  ├── code_review/
  │   ├── SKILL.md          # Main skill file with YAML front matter
  │   ├── helper.py         # Optional auxiliary files
  │   └── templates/
  └── summarization/
      └── SKILL.md
```

**SKILL.md Format**:
```markdown
---
name: Code Review
description: Reviews code for quality and best practices
---

## Overview
[Instructions for the LLM]

## Examples
[Markdown examples]
```

**Usage**:
```dart
// Initialize at startup
await SkillRegistry.instance.initialize();

// Get all skills
final skills = SkillRegistry.instance.skills;

// Use in system prompt
systemPrompt += skillRegistry.buildPromptFromSkills(['code_review']);
```

---

### 2. **Model Registry** (`lib/services/model_registry.dart`)
Tool models that can be called by the main LLM (not LLM models themselves).

**Storage**: SharedPreferences (JSON)

**Example Use**: Code review model, translation model, summarization

**Crud**:
```dart
// Initialize
await ModelRegistry.instance.initialize();

// Add model
final def = await ModelRegistry.instance.add(
  displayName: 'Code Reviewer',
  description: 'Reviews code for bugs',
  route: ModelRouteConfig(...),
);

// Export for LLM tool calling
final schema = ModelRegistry.instance.toLLMToolDefinitions();
```

---

### 3. **CLI Tool Registry** (`lib/services/cli_tool_registry.dart`)
External executable tools.

**Location**: `~/shepaw/cli-tools/`

**Structure**:
```
cli-tools/
  ├── my_analyzer/
  │   ├── cli-tool.json     # Manifest
  │   ├── handler.sh        # Handler script (stdin/stdout JSON)
  │   └── requirements.txt
```

**cli-tool.json Format**:
```json
{
  "namespace": "analyzer",
  "displayName": "My Analyzer",
  "description": "Analyzes code",
  "supportedPlatforms": ["macos", "linux", "windows"],
  "handler": {
    "type": "script",
    "path": "handler.sh"
  },
  "parameters": {
    "type": "object",
    "properties": {...}
  }
}
```

**Communication Protocol**: JSON stdin/stdout
```json
// Request
{"command": "analyze", "flags": {"file": "main.py"}}

// Response
{"success": true, "data": {"issues": [...]}}
```

---

### 4. **OS Tool Registry** (`lib/clis/shepaw/os/os_tool_registry.dart`)
Built-in OS operations (shell, file I/O, processes, etc).

**Tool Categories**:
- `os.command.*` - Shell execution, system info
- `os.file.*` - File operations
- `os.process.*` - Process management
- `os.app.*` - Application control
- `os.clipboard.*` - Clipboard operations

**Risk Levels**: safe / lowRisk / highRisk

**Platform Filtering**: Per-tool support matrix

**Execution**:
```dart
// In agent handler
final result = await OsExecutor.runTool(
  name: 'shell_exec',
  parameters: {'command': 'ls -la'},
  permissionLevel: 'dangerous',
);
```

---

### 5. **UI Component Registry** (`lib/services/ui_component_registry.dart`)
Interactive UI components agents can use.

**Components**:
- `action_confirmation` - Button prompts
- `single_select` - Radio buttons
- `multi_select` - Checkboxes
- `form` - Complex forms
- `file_upload` - File attachment
- `message_metadata` - Task state

**Export for LLM**:
```dart
// UI components are exported as tool definitions
final schema = UIComponentRegistry.instance.toLLMToolDefinitions();
// Agent receives as callable tools, responses handled automatically
```

---

## Adding a New Agent

### Step 1: Create via RemoteAgentService
```dart
final agent = await remoteAgentService.createAgent(
  name: 'My AI Assistant',
  protocol: ProtocolType.acp,
  connectionType: ConnectionType.websocket,
  endpoint: 'wss://my-agent-server.com/ws',
  avatar: '🤖',
  metadata: {
    'target_agent_id': 'agent-uuid',
  },
);
```

### Step 2: Or Use UI (Add Remote Agent Screen)
- File: `lib/screens/add_remote_agent_screen.dart` (48KB)
- Provides wizard for:
  - Agent name, avatar, description
  - Connection type (WebSocket/HTTP)
  - Protocol (ACP/custom)
  - Endpoint configuration
  - Authentication token setup

### Step 3: For Local LLM Agents
```dart
final agent = await remoteAgentService.createAgent(
  name: 'Claude Local',
  protocol: ProtocolType.acp,
  connectionType: ConnectionType.http,
  metadata: {
    'llm_provider': 'claude',
    'llm_model': 'claude-3-sonnet-20240229',
    'llm_api_base': 'https://api.anthropic.com',
    'llm_api_key': 'sk-ant-...',  // Via Secure Storage
    'system_prompt': 'You are a helpful assistant.',
  },
);
```

---

## Message Handling Flow

### 1. **Message Creation**
```dart
// User sends message
await chatService.sendMessage(
  channelId: 'channel-1',
  content: 'What is Dart?',
  agentId: 'agent-1',
);
```

### 2. **Routing**
```dart
// Chat Service determines agent type
if (agent.metadata.containsKey('llm_provider')) {
  // Local LLM Agent
  yield* localLLMService.chat(agent: agent, message: message);
} else {
  // Remote Agent (ACP or custom)
  await acpConnection.sendMessage(message);
}
```

### 3. **Response Streaming**
```dart
// For Local LLM: Stream<LLMStreamEvent>
stream.listen((event) {
  if (event is LLMTextEvent) {
    updateMessageBubble(event.text);
  } else if (event is LLMToolCallEvent) {
    executeToolCall(event.toolName, event.toolInput);
  }
});

// For Remote Agent: TaskCallbacks
callbacks.onTextContent = (data) => updateMessageBubble(data['text']);
callbacks.onActionConfirmation = (data) => showButtons(data);
```

### 4. **Persistence**
```dart
// Save final message to SQLite
await databaseService.createMessage(
  id: messageId,
  channelId: channelId,
  senderId: agentId,
  senderType: 'agent',
  content: fullResponse,
  messageType: 'text',
);

// Update inference log
await inferenceLogService.logInference(
  agentId: agentId,
  channelId: channelId,
  inputTokens: event.inputTokens,
  outputTokens: event.outputTokens,
);
```

### 5. **UI Update**
```dart
// StreamController notifies listeners
_messageControllers[channelId].add(messages);

// Chat Screen rebuilds
StreamBuilder(
  stream: chatService.watchMessages(channelId),
  builder: (context, snapshot) {
    return ListView(
      children: messages.map((m) => MessageBubble(message: m)).toList(),
    );
  },
);
```

---

## Adding New Tool to LLM

### Option 1: Built-in OS Tool
Already registered in `OsToolRegistry` - just update risk level or add platform.

### Option 2: Custom Skill
```markdown
# Create ~/shepaw/skills/my_tool/SKILL.md
---
name: My Tool
description: Does something useful
---

## Instructions
When the user asks you to [action], use this tool...

[Examples]
```

### Option 3: Model Registry
```dart
final model = await modelRegistry.add(
  displayName: 'Code Analyzer',
  description: 'Analyzes code for issues',
  route: ModelRouteConfig(
    type: 'http',
    endpoint: 'http://analyzer:8000/analyze',
  ),
);
```

---

## Environment & Configuration

### Build-Time (Environment Variables)
```bash
flutter run -d macos \
  --dart-define=ENVIRONMENT=development \
  --dart-define=API_URL=http://localhost:8080 \
  --dart-define=ENABLE_LOGGING=true
```

### Runtime (SharedPreferences)
```dart
// In app
final prefs = await SharedPreferences.getInstance();
prefs.setString('acp_server_port', '18790');
prefs.setBool('acp_server_enabled', true);
```

### Secure Storage (Encrypted)
```dart
final storage = FlutterSecureStorage();
await storage.write(key: 'api_key', value: 'sk-...');
final key = await storage.read(key: 'api_key');
```

---

## Debugging Tips

### 1. **Enable Logging**
```dart
LoggerService().debug('Message', tag: 'MyClass');
LoggerService().info('User action', tag: 'ChatScreen');
LoggerService().error('Error occurred', tag: 'Service', error: e);
```

### 2. **Trace Service**
```dart
// Auto-traces all API calls
await traceService.logTrace(
  endpoint: '/api/agents',
  method: 'GET',
  duration: duration,
  statusCode: 200,
);
```

### 3. **Inspect Database**
```dart
// Check messages
final messages = await db.getMessages('channel-1', limit: 10);

// Check agents
final agents = await db.getAllAgents();

// Check inference logs
final logs = await db.getInferenceLogs(limit: 100);
```

### 4. **WebSocket Debugging**
- ACP connection logs go to `LoggerService` with tag `'ACP'`
- Check connection state: `acpConnection.isConnected`
- Check auth state: `acpConnection.isAuthenticated`

---

## Testing

### Run All Tests
```bash
flutter test
```

### Run Specific Test
```bash
flutter test test/models/
flutter test test/integration/
```

### Mock Agent Testing
- `scripts/mock_agents/` contains test agent implementations
- Useful for testing ACP protocol without real agents

---

## Documentation Files in Project

1. **SHEPAW_EXPLORATION.md** - Comprehensive project overview
2. **ARCHITECTURE_DIAGRAM.txt** - Visual system architecture
3. **QUICK_START_GUIDE.md** - This file
4. **docs/USER_GUIDE_EN.md** - End-user manual
5. **docs/agent_integration_guide.md** - ACP SDK reference
6. **docs/remote_llm_agent_integration_en.md** - Third-party agent setup
7. **BUILD_GUIDE.md** - Platform build instructions
8. **DEVELOPMENT.md** - Code style & workflow

---

## Common Tasks

### Task: Add Support for New LLM Provider
1. Update `LocalLLMAgentService.resolveProviderType()`
2. Add provider-specific request builder (e.g., `_buildClaudeRequest()`)
3. Add provider-specific streaming parser (e.g., `_parseClaudeSSE()`)
4. Test with mock messages

**Files**: `lib/services/local_llm_agent_service.dart`

### Task: Add New Permission Level
1. Update `PermissionService` permission enums
2. Add risk level to `OsToolRegistry` tool definition
3. Create dialog in `os_tool_confirmation_dialog.dart`
4. Test permission flow

**Files**: `lib/services/permission_service.dart`, `lib/widgets/os_tool_confirmation_dialog.dart`

### Task: Add New Group Mode
1. Create handler in `lib/services/group/`
2. Update `GroupOrchestrationService.sendMessageToGroup()`
3. Add UI in `chat_screen.dart` or new screen
4. Test with mock agents

**Files**: `lib/services/group/group_orchestration_service.dart`

---

## Performance Considerations

1. **Message Streaming**: Use `StreamBuilder` with `stream: chatService.watchMessages()`
2. **Large History**: Paginate with `limit` parameter in `loadChannelMessages()`
3. **Database**: Use indexes on frequently queried columns (channelId, agentId)
4. **WebSocket**: Connection pooling via `_acpConnections` in ChatService
5. **SSE Parsing**: Stream-based parsing, not buffering entire response

---

## Next Steps

1. Read `SHEPAW_EXPLORATION.md` for complete architecture
2. Study `chat_service.dart` to understand message flow
3. Look at `lib/screens/chat_screen.dart` to see UI integration
4. Review `local_llm_agent_service.dart` for LLM API patterns
5. Check `group_orchestration_service.dart` for advanced coordination


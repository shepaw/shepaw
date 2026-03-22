# Tool Model Architecture (工具模型架构)

> Paw v1.x | Last updated: 2026-03-06

---

## Overview

The **Tool Model** mechanism allows globally configured LLM endpoints to be exposed as callable tools to the main LLM. Instead of a separate intent-classifier deciding which model to route to (the deprecated `CustomModality` approach), the main LLM itself decides when to delegate work to a specialised model via standard tool/function calling.

### Key Benefits

- **No extra classifier call** — the main LLM decides routing, eliminating latency and cost from an intermediate classification step.
- **Global configuration** — tool models are defined once in Settings and can be enabled per-Agent.
- **Composable** — tool models coexist with OS tools, skills, and UI components in the same tool-calling loop.
- **Result integration** — the tool model result is fed back to the main LLM, which synthesises a final user-facing response.

---

## Architecture Diagram

```
User Message
     │
     ▼
┌─────────────────────────────────────────────────┐
│                  Main LLM                       │
│  (agent's configured provider + model)          │
│                                                 │
│  System prompt includes:                        │
│   - Base system prompt                          │
│   - UI component tools                          │
│   - OS tools (if enabled)                       │
│   - Skill tools (if enabled)                    │
│   - Tool Model tools (if enabled)  ◄── NEW      │
│                                                 │
│  The LLM decides via tool_call whether          │
│  to invoke a tool model.                        │
└────────────┬────────────────────────────────────┘
             │
             │ tool_call: tool_model_image_gen(prompt: "a cat")
             ▼
┌─────────────────────────────────────────────────┐
│           ToolModelRegistry                     │
│  executeToolModel(toolName, arguments)          │
│                                                 │
│  - Resolves the ToolModelDefinition             │
│  - Builds HTTP request using ModelRouteConfig   │
│    (apiBase, model, apiKey, apiPath,            │
│     requestBodyTemplate, responseBodyPath)       │
│  - Calls the target model API                   │
│  - Extracts result via responseBodyPath         │
│    or standard OpenAI response format           │
└────────────┬────────────────────────────────────┘
             │
             │ tool_result: "![Generated Image](https://...)"
             ▼
┌─────────────────────────────────────────────────┐
│                  Main LLM                       │
│  Receives tool result, synthesises final        │
│  response for the user.                         │
└─────────────────────────────────────────────────┘
```

---

## Data Model

### ToolModelDefinition (`lib/models/tool_model_definition.dart`)

| Field | Type | Description |
|-------|------|-------------|
| `id` | `String` | UUID, auto-generated |
| `toolName` | `String` | Function-calling name, prefixed `tool_model_` (e.g. `tool_model_image_gen`) |
| `displayName` | `String` | Human-readable name shown in UI |
| `description` | `String` | Exposed to the main LLM so it knows when to call this tool |
| `route` | `ModelRouteConfig` | Reused from `model_routing_config.dart` — contains provider, model, apiBase, apiKey, stream, apiPath, requestBodyTemplate, responseBodyPath |

### Tool Parameter Schema

Every tool model exposes a single parameter to the LLM:

```json
{
  "prompt": {
    "type": "string",
    "description": "The prompt or instruction to send to the <displayName> model."
  }
}
```

---

## Registry (`lib/services/tool_model_registry.dart`)

Singleton: `ToolModelRegistry.instance`

### Lifecycle

1. **`initialize()`** — Called in `main.dart` after `SkillRegistry.instance.initialize()`. Loads definitions from `SharedPreferences` (key: `tool_model_definitions`).
2. **CRUD** — `add()`, `update()`, `delete()` mutate the in-memory list and persist via `_persist()`.
3. **Lookups** — `isToolModelTool(name)`, `getDefinition(toolName)`, `getById(id)`.

### LLM Integration

| Method | Description |
|--------|-------------|
| `openAITools(enabledToolModels:)` | Returns tool definitions in OpenAI function-calling format |
| `claudeTools(enabledToolModels:)` | Returns tool definitions in Anthropic Claude format |
| `systemPromptSuffix(enabledToolModels)` | Appends available tool model descriptions to the system prompt |

### Execution

`executeToolModel(toolName, arguments)`:
1. Looks up the `ToolModelDefinition` by tool name.
2. Resolves the API endpoint URL using `apiBase` + `apiPath` (defaults to `/chat/completions`).
3. Builds the request body:
   - If `requestBodyTemplate` is set: performs `$model` / `$prompt` variable substitution.
   - Otherwise: sends a standard OpenAI chat/completions JSON body with `stream: false`.
4. Sends HTTP POST with `Authorization: Bearer <apiKey>`.
5. Extracts result:
   - If `responseBodyPath` is set: uses `resolveJsonPath()` (e.g. `data[0].url`).
   - Otherwise: extracts `choices[0].message.content` from standard OpenAI response.
6. Returns the result string back to the calling loop.

---

## Agent Configuration

### Per-Agent Enablement

Tool models are enabled per-agent via `metadata['enabled_tool_models']` (a `List<String>` of tool names).

Accessed via:
```dart
RemoteAgent.enabledToolModels  // → Set<String>
RemoteAgent.hasToolModels      // → bool
```

### Configuration Screens

- **Settings → Model Management** (`tool_model_management_screen.dart`): Global CRUD for model definitions. Description is optional — when empty and used as a tool model, the display name serves as fallback.
- **Agent Create/Edit → Models** (`tool_model_select_screen.dart` + `tool_model_config_card.dart`): Toggle which globally-defined models this agent should use. Includes a FAB to add new models inline — they are persisted to the global registry for reuse by other agents.

---

## ChatService Integration (`lib/services/chat_service.dart`)

The tool model integration follows the same pattern as OS tools and skills:

### 1. Tool List Construction (~line 1080)

```dart
combinedTools = [
  ...UIComponentRegistry.instance.openAITools(),
  if (hasOsTools)    ...osRegistry.openAITools(...),
  if (hasSkills)     ...skillRegistry.openAITools(...),
  if (hasToolModels) ...toolModelRegistry.openAITools(...),  // NEW
];
```

### 2. System Prompt (~line 1097)

```dart
final systemPrompt = '$baseSystemPrompt'
    '${UIComponentRegistry.instance.systemPromptSuffix}'
    '${hasOsTools ? osRegistry.systemPromptSuffix(...) : ''}'
    '${hasSkills ? skillRegistry.systemPromptSuffix(...) : ''}'
    '${hasToolModels ? toolModelRegistry.systemPromptSuffix(...) : ''}';  // NEW
```

### 3. Multi-Round Loop Entry (~line 1140)

```dart
// Previously: if (!hasOsTools && !hasSkills) → single-round
// Now:        if (!hasOsTools && !hasSkills && !hasToolModels) → single-round
```

### 4. Tool Call Classification (~line 1225)

```dart
for (final tc in toolCallEvents) {
  if (_isUiTool(tc.name))                      → uiToolCalls
  else if (osRegistry.isOsTool(tc.name))       → osToolCalls
  else if (skillRegistry.isSkillTool(tc.name)) → skillToolCalls
  else if (toolModelRegistry.isToolModelTool(tc.name)) → toolModelCalls  // NEW
}
```

### 5. Execution (~line 1275)

```dart
if (toolModelRegistry.isToolModelTool(tc.name)) {
  // Show "[Calling tool model: Image Generation]" in stream
  final result = await toolModelRegistry.executeToolModel(tc.name, tc.arguments);
  // Feed result back as tool_result for next LLM round
}
```

---

## Deprecated: CustomModality Intent Classification

The `CustomModality` mechanism (intent classification via a separate small-model call) has been deprecated:

- **`_classifyAndResolve()`** in `local_llm_agent_service.dart` now skips intent classification for pure-text messages. Only attachment-based modality detection (image/audio/video) remains.
- **Custom Modalities UI** in `model_routing_config_card.dart` is hidden (commented out).
- **`CustomModality` class** is retained in `model_routing_config.dart` for backward compatibility with persisted data.

### Migration Path

If agents have existing `custom_modalities` in their `model_routing` metadata:
1. Create equivalent Tool Model definitions in Settings → Tool Model Management.
2. Enable them on the relevant agents.
3. The custom modalities data can remain — it is simply ignored.

---

## File Inventory

| Operation | File | Purpose |
|-----------|------|---------|
| NEW | `lib/models/tool_model_definition.dart` | Data model |
| NEW | `lib/services/tool_model_registry.dart` | Registry + execution |
| NEW | `lib/screens/tool_model_management_screen.dart` | Global CRUD UI |
| NEW | `lib/screens/tool_model_select_screen.dart` | Per-agent selection UI |
| NEW | `lib/widgets/tool_model_config_card.dart` | Toggle card widget |
| MOD | `lib/main.dart` | Initialize registry at startup |
| MOD | `lib/models/remote_agent.dart` | `enabledToolModels` / `hasToolModels` getters |
| MOD | `lib/services/chat_service.dart` | 5 integration points in tool-calling loop |
| MOD | `lib/screens/settings_screen.dart` | Management entry in settings |
| MOD | `lib/screens/add_remote_agent_screen.dart` | Agent creation with tool models |
| MOD | `lib/screens/remote_agent_detail_screen.dart` | Agent detail view + edit |
| MOD | `lib/services/local_llm_agent_service.dart` | Deprecated intent classification |
| MOD | `lib/widgets/model_routing_config_card.dart` | Hidden custom modalities UI |
| MOD | `lib/l10n/app_en.arb` | English strings (~25 keys) |
| MOD | `lib/l10n/app_zh.arb` | Chinese strings (~25 keys) |

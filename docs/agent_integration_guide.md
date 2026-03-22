# ACP Agent Integration Guide

> Third-party Agent integration development guide for AI Agent Hub
>
> Protocol version: ACP 1.0 | Last updated: 2026-03-01

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Quick Start](#2-quick-start)
3. [Using the Python SDK (Recommended)](#3-using-the-python-sdk-recommended)
4. [Protocol Specification](#4-protocol-specification)
5. [Message Lifecycle](#5-message-lifecycle)
6. [UI Interactive Components](#6-ui-interactive-components)
7. [File Transfer](#7-file-transfer)
8. [Conversation History Management](#8-conversation-history-management)
9. [Complete Example (Raw Protocol)](#9-complete-example-raw-protocol)
10. [Error Codes Reference](#10-error-codes-reference)
11. [FAQ](#11-faq)

---

## 1. Architecture Overview

### 1.1 What is ACP

ACP (Agent Communication Protocol) is a **bidirectional JSON-RPC 2.0 over WebSocket** protocol used for communication between the AI Agent Hub App and remote agents.

```
┌──────────────────┐         WebSocket (JSON-RPC 2.0)         ┌──────────────────┐
│                  │ ◄──────────────────────────────────────► │                  │
│   AI Agent Hub   │   App→Agent: agent.chat, agent.cancel    │   Your Agent     │
│   (Flutter App)  │   Agent→App: ui.textContent, task.*      │   (Python/Any)   │
│                  │   Agent→App: hub.* requests               │                  │
└──────────────────┘                                          └──────────────────┘
```

### 1.2 Communication patterns

| Direction | Type | Examples |
|-----------|------|----------|
| App → Agent | Request | `agent.chat`, `agent.cancelTask`, `agent.submitResponse`, `agent.rollback`, `agent.getCard` |
| Agent → App | Notification | `ui.textContent`, `ui.actionConfirmation`, `ui.form`, `task.started`, `task.completed`, `task.error` |
| Agent → App | Request | `hub.getUIComponentTemplates`, `hub.getSessions`, `hub.getSessionMessages` |
| Bidirectional | Heartbeat | `ping` / `pong` |

### 1.3 Your Agent's responsibilities

To integrate with AI Agent Hub, your Agent needs to:

1. **Start a WebSocket server** at a known endpoint (e.g. `ws://host:port/acp/ws`)
2. **Handle authentication** via `auth.authenticate`
3. **Process chat messages** via `agent.chat` and stream responses back
4. **Send streaming text** via `ui.textContent` notifications
5. **Report task lifecycle** via `task.started` / `task.completed` / `task.error`

Optional:
- Respond to `ping` heartbeats
- Send interactive UI components (buttons, forms, selects)
- Transfer files via HTTP or WebSocket binary frames
- Request conversation history from the App via `hub.*`

---

## 2. Quick Start

> **For Python developers**: See [Section 3 — Using the Python SDK](#3-using-the-python-sdk-recommended) for a much simpler approach using `paw_acp_sdk`.
>
> The raw protocol example below is useful for understanding the protocol internals or building agents in other languages.

### 2.1 Dependencies

```bash
pip install aiohttp
```

### 2.2 Minimal agent in 80 lines

```python
#!/usr/bin/env python3
"""Minimal ACP Agent - the smallest possible integration."""

import asyncio
import json
import uuid
from datetime import datetime
from aiohttp import web

def jsonrpc_response(id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result if result is not None else {}
    return msg

def jsonrpc_notification(method, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    return msg

async def handle_websocket(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    authenticated = False

    async for msg in ws:
        if msg.type != web.WSMsgType.TEXT:
            continue
        data = json.loads(msg.data)
        method = data.get("method")
        msg_id = data.get("id")
        params = data.get("params", {})

        # --- Authentication ---
        if method == "auth.authenticate":
            token = params.get("token", "")
            if token == "my-secret-token":  # Replace with your auth logic
                authenticated = True
                await ws.send_json(jsonrpc_response(msg_id, {"status": "authenticated"}))
            else:
                await ws.send_json(jsonrpc_response(msg_id, error={"code": -32000, "message": "Auth failed"}))
            continue

        # --- Heartbeat ---
        if method == "ping":
            await ws.send_json(jsonrpc_response(msg_id, {"pong": True}))
            continue

        if not authenticated:
            await ws.send_json(jsonrpc_response(msg_id, error={"code": -32000, "message": "Not authenticated"}))
            continue

        # --- Chat ---
        if method == "agent.chat":
            task_id = params.get("task_id", str(uuid.uuid4()))
            message = params.get("message", "")

            # 1. Acknowledge the request
            await ws.send_json(jsonrpc_response(msg_id, {"task_id": task_id, "status": "accepted"}))

            # 2. Notify: task started
            await ws.send_json(jsonrpc_notification("task.started", {
                "task_id": task_id, "started_at": datetime.now().isoformat()
            }))

            # 3. Stream response text (your LLM / business logic here)
            reply = f"You said: {message}"
            for i in range(0, len(reply), 5):
                chunk = reply[i:i+5]
                await ws.send_json(jsonrpc_notification("ui.textContent", {
                    "task_id": task_id, "content": chunk, "is_final": False
                }))
                await asyncio.sleep(0.05)

            # 4. Send final text marker
            await ws.send_json(jsonrpc_notification("ui.textContent", {
                "task_id": task_id, "content": "", "is_final": True
            }))

            # 5. Notify: task completed
            await ws.send_json(jsonrpc_notification("task.completed", {
                "task_id": task_id, "status": "success", "completed_at": datetime.now().isoformat()
            }))

        # --- Agent Card ---
        elif method == "agent.getCard":
            await ws.send_json(jsonrpc_response(msg_id, {
                "agent_id": "my-agent",
                "name": "My Agent",
                "description": "A minimal ACP agent",
                "version": "1.0.0",
                "capabilities": ["chat", "streaming"],
                "supported_protocols": ["acp"],
            }))

        else:
            await ws.send_json(jsonrpc_response(msg_id, error={"code": -32601, "message": f"Method not found: {method}"}))

    return ws

app = web.Application()
app.router.add_get("/acp/ws", handle_websocket)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=8080)
```

### 2.3 Run and register

```bash
# Start your agent
python minimal_agent.py

# In the App, add a remote agent:
#   Address: ws://<your-ip>:8080/acp/ws
#   Token: my-secret-token
```

---

## 3. Using the Python SDK (Recommended)

For Python agents, the `paw_acp_sdk` package handles all protocol boilerplate — authentication, heartbeat, task lifecycle, conversation history, hub request tracking — so you only write your agent logic.

### 3.1 Installation

```bash
cd agents/paw_acp_sdk
pip install -e .
```

Or just install the dependency directly:

```bash
pip install aiohttp
```

### 3.2 Minimal agent (~10 lines)

```python
from paw_acp_sdk import ACPAgentServer, TaskContext

class EchoAgent(ACPAgentServer):
    async def on_chat(self, ctx: TaskContext, message: str, **kwargs):
        await ctx.send_text(f"You said: {message}")

EchoAgent(name="Echo Agent", token="my-secret").run(port=8080)
```

That's it. The base class handles:

- WebSocket server at `/acp/ws`
- `auth.authenticate` — token validation
- `ping` / `pong` — heartbeat
- `agent.chat` — dispatches to your `on_chat()`
- `agent.cancelTask` — cancels the async task
- `agent.submitResponse` — routes interactive responses
- `agent.rollback` — removes last conversation turn
- `agent.getCard` — returns agent metadata
- `task.started` / `task.completed` / `task.error` — automatic lifecycle
- `ui.textContent` final marker — sent automatically after `on_chat` returns
- Session history — managed via `ConversationManager`

### 3.3 LLM agent with streaming

```python
from paw_acp_sdk import (
    ACPAgentServer, TaskContext,
    OpenAIProvider, ACPDirectiveStreamParser, ACPTextChunk, ACPDirective,
)

class LLMAgent(ACPAgentServer):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.provider = OpenAIProvider(
            api_base="https://api.openai.com/v1",
            api_key="sk-...",
            model="gpt-4o",
        )

    async def on_chat(self, ctx: TaskContext, message: str, **kwargs):
        messages = kwargs.get("messages", [])
        system_prompt = kwargs.get("system_prompt", self.system_prompt)

        parser = ACPDirectiveStreamParser()
        full_reply = ""

        async for chunk in self.provider.stream_chat(messages, system_prompt):
            full_reply += chunk
            for event in parser.feed(chunk):
                if isinstance(event, ACPTextChunk) and event.content:
                    await ctx.send_text(event.content)
                elif isinstance(event, ACPDirective):
                    await ctx.send_text(f"[Directive: {event.directive_type}]")

        for event in parser.flush():
            if isinstance(event, ACPTextChunk) and event.content:
                await ctx.send_text(event.content)

        self.save_reply_to_history(ctx.session_id, full_reply)

LLMAgent(name="My LLM Agent", token="secret").run(port=8080)
```

### 3.4 TaskContext API

The `ctx` object passed to `on_chat` provides these methods:

| Method | Description |
|--------|-------------|
| `ctx.send_text(content)` | Send a streaming text chunk |
| `ctx.send_text_final()` | Send final text marker (called automatically) |
| `ctx.started()` | Send `task.started` (called automatically) |
| `ctx.completed()` | Send `task.completed` (called automatically) |
| `ctx.error(message, code)` | Send `task.error` |
| `ctx.send_action_confirmation(prompt, actions)` | Send action buttons |
| `ctx.send_single_select(prompt, options)` | Send radio selection |
| `ctx.send_multi_select(prompt, options)` | Send checkbox selection |
| `ctx.send_file_upload(prompt)` | Request file upload |
| `ctx.send_form(title, fields)` | Send structured form |
| `ctx.send_file_message(url, filename)` | Send file to user |
| `ctx.send_message_metadata(collapsible_title=...)` | Add collapsible metadata |
| `ctx.hub_request(method, params)` | Send request to App, await response |
| `ctx.wait_for_response(component_id)` | Wait for user interactive response |

### 3.5 Available LLM providers

| Class | Backend | Notes |
|-------|---------|-------|
| `OpenAIProvider` | OpenAI, DeepSeek, Qwen, Ollama, vLLM, LM Studio | Any OpenAI-compatible API |
| `ClaudeProvider` | Anthropic Claude | Claude 3.5/4 series |
| `GLMProvider` | ZhipuAI GLM | GLM-4, GLM-4.7 with JWT auth |

All providers support `stream_chat()` and `stream_chat_with_tools()`.

### 3.6 SDK vs Raw Protocol — comparison

| Aspect | Raw protocol (Section 2) | SDK (`paw_acp_sdk`) |
|--------|--------------------------|---------------------|
| Lines of code | ~80 for minimal, ~300 for production | ~10 for minimal, ~50 for production |
| Auth handling | Manual | Automatic |
| Heartbeat | Manual | Automatic |
| Task lifecycle | Manual `task.started`/`completed`/`error` | Automatic |
| Cancel support | Manual async task tracking | Automatic |
| History management | Manual | Built-in `ConversationManager` |
| Hub requests | Manual future tracking | `ctx.hub_request()` |
| Interactive responses | Manual future resolution | `ctx.wait_for_response()` |
| Language | Any (WebSocket + JSON-RPC) | Python only |

> **When to use the raw protocol**: Non-Python agents, or when you need full control over the WebSocket lifecycle.

### 3.7 Package structure

```
agents/paw_acp_sdk/
├── pyproject.toml
├── paw_acp_sdk/
│   ├── __init__.py             # Public API exports
│   ├── jsonrpc.py              # JSON-RPC 2.0 message builders
│   ├── types.py                # ACPTextChunk, ACPDirective, AgentCard, LLMToolCall, LLMStreamResult
│   ├── directive_parser.py     # ACPDirectiveStreamParser
│   ├── conversation.py         # ConversationManager
│   ├── task_context.py         # TaskContext (per-task helper)
│   ├── server.py               # ACPAgentServer base class
│   └── providers.py            # OpenAIProvider, ClaudeProvider, GLMProvider
└── examples/
    ├── echo_agent.py           # Minimal agent
    └── llm_agent_example.py    # LLM agent with streaming
```

---

## 4. Protocol Specification

### 4.1 Transport

- **Protocol**: WebSocket (RFC 6455)
- **Endpoint**: Agent exposes `ws://<host>:<port>/acp/ws`
- **Encoding**: All text frames are UTF-8 JSON-RPC 2.0
- **Binary frames**: Used only for file transfer (see [Section 7](#7-file-transfer))

### 4.2 JSON-RPC 2.0 message types

**Request** (has both `id` and `method`):
```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "params": { ... },
  "id": 1
}
```

**Response** (has `id`, no `method`):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { ... }
}
```

**Error Response**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32602, "message": "Missing 'message' parameter" }
}
```

**Notification** (has `method`, no `id`):
```json
{
  "jsonrpc": "2.0",
  "method": "ui.textContent",
  "params": { "task_id": "xxx", "content": "Hello", "is_final": false }
}
```

### 4.3 App → Agent requests

#### `auth.authenticate`

The first message the App sends after WebSocket connection is established.

```json
// Request
{ "jsonrpc": "2.0", "method": "auth.authenticate", "params": { "token": "your-token" }, "id": 1 }

// Success
{ "jsonrpc": "2.0", "id": 1, "result": { "status": "authenticated" } }

// Failure
{ "jsonrpc": "2.0", "id": 1, "error": { "code": -32000, "message": "Authentication failed" } }
```

#### `ping`

Heartbeat sent every 30 seconds by the App.

```json
// Request
{ "jsonrpc": "2.0", "method": "ping", "params": {}, "id": 2 }

// Response
{ "jsonrpc": "2.0", "id": 2, "result": { "pong": true } }
```

> **Note**: If the agent fails to respond to 3 consecutive pings, the App will disconnect.

#### `agent.chat`

The core request — delivers a user message and triggers the agent to respond.

```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "id": 3,
  "params": {
    "task_id": "task_abc123",
    "session_id": "session_xyz",
    "message": "What's the weather like?",
    "user_id": "user_001",
    "message_id": "msg_001",
    "history": [
      { "role": "user", "content": "Hello" },
      { "role": "assistant", "content": "Hi there!" }
    ],
    "total_message_count": 10,
    "ui_component_version": "1.0.0",
    "system_prompt": null,
    "group_context": null
  }
}
```

**Params breakdown:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `task_id` | string | Yes | Unique task ID for this request |
| `session_id` | string | Yes | Session/conversation ID for context management |
| `message` | string | Yes* | User's message text |
| `user_id` | string | Yes | ID of the user who sent the message |
| `message_id` | string | Yes | ID of this specific message |
| `history` | array | No | Conversation history (for new sessions or history sync) |
| `total_message_count` | int | No | Total messages in App's session (for gap detection) |
| `ui_component_version` | string | No | Version of the App's UI component registry |
| `history_supplement` | bool | No | `true` if this is a history supplement (see [Section 8](#8-conversation-history-management)) |
| `additional_history` | array | No | Older history messages to prepend |
| `original_question` | string | No | Original question when re-answering after history supplement |
| `system_prompt` | string | No | System prompt override (e.g. for group chat context) |
| `group_context` | object | No | Group chat metadata |

**Expected response flow:**

```python
# Step 1: Immediately acknowledge
await ws.send_json(jsonrpc_response(msg_id, {"task_id": task_id, "status": "accepted"}))

# Step 2: Send task.started notification
await ws.send_json(jsonrpc_notification("task.started", {
    "task_id": task_id, "started_at": datetime.now().isoformat()
}))

# Step 3: Stream text via ui.textContent notifications (see Section 3.4)
# Step 4: Send ui.textContent with is_final=True
# Step 5: Send task.completed notification
```

#### `agent.cancelTask`

Cancel a running task.

```json
{ "jsonrpc": "2.0", "method": "agent.cancelTask", "params": { "task_id": "task_abc123" }, "id": 4 }
```

Response:
```json
{ "jsonrpc": "2.0", "id": 4, "result": { "task_id": "task_abc123", "status": "cancelled" } }
```

#### `agent.submitResponse`

User submitted an interactive response (clicked a button, submitted a form, etc.).

```json
{
  "jsonrpc": "2.0",
  "method": "agent.submitResponse",
  "id": 5,
  "params": {
    "task_id": "task_abc123",
    "response_type": "action_confirmation",
    "response_data": {
      "confirmation_id": "confirm_1a2b3c",
      "selected_action_id": "approve"
    }
  }
}
```

#### `agent.rollback`

Remove the last assistant+user message pair from the conversation.

```json
{ "jsonrpc": "2.0", "method": "agent.rollback", "params": { "session_id": "session_xyz", "message_id": "msg_001" }, "id": 6 }
```

#### `agent.getCard`

Get the agent's capabilities metadata.

```json
// Request
{ "jsonrpc": "2.0", "method": "agent.getCard", "params": {}, "id": 7 }

// Response
{
  "jsonrpc": "2.0", "id": 7,
  "result": {
    "agent_id": "my-agent-001",
    "name": "My Agent",
    "description": "An AI agent that helps with tasks",
    "version": "1.0.0",
    "capabilities": ["chat", "streaming", "interactive_messages"],
    "supported_protocols": ["acp"]
  }
}
```

### 4.4 Agent → App notifications

#### `ui.textContent` — Streaming text

This is the primary response mechanism. Send text chunks as they become available.

```json
// Streaming chunk
{ "jsonrpc": "2.0", "method": "ui.textContent", "params": { "task_id": "task_abc123", "content": "Here is a ", "is_final": false } }

// Another chunk
{ "jsonrpc": "2.0", "method": "ui.textContent", "params": { "task_id": "task_abc123", "content": "partial answer...", "is_final": false } }

// Final marker (REQUIRED — signals the text stream is complete)
{ "jsonrpc": "2.0", "method": "ui.textContent", "params": { "task_id": "task_abc123", "content": "", "is_final": true } }
```

> **IMPORTANT**: You MUST send a final `ui.textContent` with `is_final: true` before sending `task.completed`. The App uses this to finalize the message bubble.

#### `task.started`

```json
{ "jsonrpc": "2.0", "method": "task.started", "params": { "task_id": "task_abc123", "started_at": "2026-03-01T10:00:00" } }
```

#### `task.completed`

```json
{ "jsonrpc": "2.0", "method": "task.completed", "params": { "task_id": "task_abc123", "status": "success", "completed_at": "2026-03-01T10:00:05" } }
```

#### `task.error`

```json
{ "jsonrpc": "2.0", "method": "task.error", "params": { "task_id": "task_abc123", "message": "LLM API error", "code": -32603 } }
```

### 4.5 Agent → App requests (hub.*)

The Agent can proactively request data from the App. These use standard JSON-RPC request/response.

#### `hub.getUIComponentTemplates`

Get the App's UI component definitions (schemas, directive prompt, supported types). This is critical for rendering interactive components correctly.

```json
// Agent sends
{ "jsonrpc": "2.0", "method": "hub.getUIComponentTemplates", "id": "req_001" }

// App responds with component definitions, tool schemas, and prompt templates
{
  "jsonrpc": "2.0", "id": "req_001",
  "result": {
    "version": "1.0.0",
    "components": [ ... ],
    "prompt_templates": {
      "system_prompt_suffix": "...",
      "acp_directive_prompt": "..."
    },
    "schemas": {
      "openai_tools": [ ... ],
      "claude_tools": [ ... ]
    }
  }
}
```

#### `hub.getSessions`

```json
{ "jsonrpc": "2.0", "method": "hub.getSessions", "id": "req_002" }
```

#### `hub.getSessionMessages`

```json
{ "jsonrpc": "2.0", "method": "hub.getSessionMessages", "params": { "session_id": "xxx", "limit": 50 }, "id": "req_003" }
```

---

## 5. Message Lifecycle

### 5.1 Complete request-response flow

```
App                                         Agent
 │                                            │
 │──── auth.authenticate ────────────────────►│
 │◄──── {status: "authenticated"} ────────────│
 │                                            │
 │──── agent.chat (task_id, message) ────────►│
 │◄──── {task_id, status: "accepted"} ────────│
 │                                            │
 │◄──── task.started ─────────────────────────│
 │◄──── ui.textContent (chunk 1) ─────────────│
 │◄──── ui.textContent (chunk 2) ─────────────│
 │◄──── ui.textContent (chunk N) ─────────────│
 │◄──── ui.textContent (is_final=true) ───────│
 │◄──── task.completed ───────────────────────│
 │                                            │
 │──── ping ─────────────────────────────────►│
 │◄──── pong ─────────────────────────────────│
```

### 5.2 Error handling flow

```
App                                         Agent
 │──── agent.chat ───────────────────────────►│
 │◄──── {status: "accepted"} ─────────────────│
 │◄──── task.started ─────────────────────────│
 │◄──── ui.textContent (partial) ─────────────│
 │     ... error occurs ...                   │
 │◄──── task.error {message, code} ───────────│
```

### 5.3 Cancellation flow

```
App                                         Agent
 │──── agent.chat ───────────────────────────►│
 │◄──── {status: "accepted"} ─────────────────│
 │◄──── task.started ─────────────────────────│
 │◄──── ui.textContent (partial) ─────────────│
 │                                            │
 │──── agent.cancelTask ─────────────────────►│
 │◄──── {status: "cancelled"} ────────────────│
 │◄──── task.error {code: -32008} ────────────│
```

### 5.4 Interactive component flow

```
App                                         Agent
 │──── agent.chat ───────────────────────────►│
 │◄──── {status: "accepted"} ─────────────────│
 │◄──── task.started ─────────────────────────│
 │◄──── ui.textContent ("Here are options:")──│
 │◄──── ui.actionConfirmation ────────────────│  (renders buttons in App)
 │◄──── ui.textContent (is_final=true) ───────│
 │◄──── task.completed ───────────────────────│
 │                                            │
 │  ... user clicks button ...                │
 │                                            │
 │──── agent.submitResponse ─────────────────►│  (or new agent.chat with user choice as text)
 │◄──── ... response flow ... ────────────────│
```

### 5.5 Implementing in Python — pattern from mac_agent

```python
async def handle_websocket(self, request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    authenticated = False

    async for msg in ws:
        if msg.type == aiohttp.WSMsgType.TEXT:
            data = json.loads(msg.data)
            method = data.get("method")
            msg_id = data.get("id")
            params = data.get("params", {})

            if msg_id is not None and method is not None:
                # This is a Request from App
                if method == "auth.authenticate":
                    # Handle auth
                    ...
                elif method == "agent.chat":
                    # Handle chat (spawn async task)
                    task = asyncio.create_task(self._process_chat(ws, msg_id, params))
                    self._active_tasks[params["task_id"]] = task
                elif method == "agent.cancelTask":
                    # Cancel the async task
                    task = self._active_tasks.get(params["task_id"])
                    if task:
                        task.cancel()
                elif method == "ping":
                    await ws.send_json(jsonrpc_response(msg_id, {"pong": True}))
                ...

            elif msg_id is not None and method is None:
                # This is a Response to OUR request (e.g. hub.* responses)
                future = self._pending_requests.pop(msg_id, None)
                if future and not future.done():
                    if data.get("error"):
                        future.set_exception(RuntimeError(data["error"]["message"]))
                    else:
                        future.set_result(data.get("result"))
```

> **Key insight**: The same WebSocket carries both request/response patterns and notification patterns in both directions. Use `id` and `method` presence to distinguish message types:
> - Has `id` + `method` → Request
> - Has `id` + no `method` → Response
> - Has `method` + no `id` → Notification

---

## 6. UI Interactive Components

Your agent can send rich interactive UI components that render in the App's chat interface. There are 8 component types available.

### 6.1 How it works

There are **two modes** for sending UI components:

| Mode | When to use | How it works |
|------|------------|--------------|
| **Directive syntax** | No tool calling / simple agents | LLM embeds `<<<directive ... >>>` blocks in text output; agent parses and converts to `ui.*` notifications |
| **Tool calling** | Tool-calling LLM agents | LLM calls UI component functions directly; agent converts to `ui.*` notifications |

Both modes result in the same `ui.*` JSON-RPC notifications to the App. The choice depends on your LLM backend's capabilities.

### 6.2 Dynamic component discovery

Before sending UI components, fetch the App's component registry via `hub.getUIComponentTemplates`. This gives you:

- **Directive prompt** — inject into system prompt for directive-syntax mode
- **OpenAI/Claude tool schemas** — merge into tool list for tool-calling mode
- **Component method map** — maps type name to ACP notification method

```python
async def _fetch_ui_components(self, ws):
    """Fetch UI components from the App (called once, cached)."""
    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    self._pending_requests[req_id] = future

    await ws.send_json({
        "jsonrpc": "2.0",
        "method": "hub.getUIComponentTemplates",
        "id": req_id,
    })

    result = await asyncio.wait_for(future, timeout=10.0)

    # Cache the results
    self._component_version = result["version"]
    self._directive_prompt = result["prompt_templates"]["acp_directive_prompt"]
    self._component_method_map = {
        comp["name"]: comp["acp_notification_method"]
        for comp in result["components"]
    }
    # For tool-calling mode:
    self._openai_ui_tools = result["schemas"]["openai_tools"]
    self._claude_ui_tools = result["schemas"]["claude_tools"]
```

### 6.3 Component reference

#### `ui.actionConfirmation` — Action buttons

```json
{
  "jsonrpc": "2.0",
  "method": "ui.actionConfirmation",
  "params": {
    "task_id": "task_abc123",
    "confirmation_id": "confirm_1a2b3c",
    "prompt": "Deploy to production?",
    "actions": [
      { "id": "approve", "label": "Deploy Now", "style": "primary" },
      { "id": "test_more", "label": "Run More Tests", "style": "secondary" },
      { "id": "cancel", "label": "Cancel", "style": "danger" }
    ]
  }
}
```

User response arrives via `agent.submitResponse`:
```json
{ "response_data": { "confirmation_id": "confirm_1a2b3c", "selected_action_id": "approve" } }
```

Or as a new `agent.chat` message: `"Selected action: Deploy Now"`

#### `ui.singleSelect` — Radio selection

```json
{
  "jsonrpc": "2.0",
  "method": "ui.singleSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "select_1a2b3c",
    "prompt": "Choose a deployment environment:",
    "options": [
      { "id": "staging", "label": "Staging" },
      { "id": "production", "label": "Production" },
      { "id": "canary", "label": "Canary (10%)" }
    ]
  }
}
```

#### `ui.multiSelect` — Checkbox selection

```json
{
  "jsonrpc": "2.0",
  "method": "ui.multiSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "mselect_1a2b3c",
    "prompt": "Select features to enable:",
    "options": [
      { "id": "dark_mode", "label": "Dark Mode" },
      { "id": "notifications", "label": "Push Notifications" },
      { "id": "offline", "label": "Offline Support" }
    ],
    "min_select": 1,
    "max_select": null
  }
}
```

#### `ui.fileUpload` — Request file upload

```json
{
  "jsonrpc": "2.0",
  "method": "ui.fileUpload",
  "params": {
    "task_id": "task_abc123",
    "upload_id": "upload_1a2b3c",
    "prompt": "Please upload your documents:",
    "accept_types": ["pdf", "doc", "docx", "txt"],
    "max_files": 5,
    "max_size_mb": 20
  }
}
```

#### `ui.form` — Structured form

```json
{
  "jsonrpc": "2.0",
  "method": "ui.form",
  "params": {
    "task_id": "task_abc123",
    "form_id": "form_1a2b3c",
    "title": "Bug Report",
    "description": "Please fill in the details.",
    "fields": [
      {
        "field_id": "title",
        "type": "text_input",
        "label": "Bug Title",
        "placeholder": "Brief description",
        "required": true,
        "max_lines": 1
      },
      {
        "field_id": "severity",
        "type": "single_select",
        "label": "Severity",
        "required": true,
        "options": [
          { "id": "critical", "label": "Critical" },
          { "id": "major", "label": "Major" },
          { "id": "minor", "label": "Minor" }
        ]
      },
      {
        "field_id": "description",
        "type": "text_input",
        "label": "Description",
        "placeholder": "Detailed description...",
        "required": true,
        "max_lines": 5
      },
      {
        "field_id": "screenshot",
        "type": "file_upload",
        "label": "Screenshot",
        "required": false,
        "accept_types": ["png", "jpg"],
        "max_files": 3,
        "max_size_mb": 10
      }
    ]
  }
}
```

Field types: `text_input`, `single_select`, `multi_select`, `file_upload`

#### `ui.fileMessage` — Send file to user

```json
{
  "jsonrpc": "2.0",
  "method": "ui.fileMessage",
  "params": {
    "task_id": "task_abc123",
    "url": "http://your-agent:8080/files/abc123",
    "filename": "report.pdf",
    "mime_type": "application/pdf",
    "size": 13264,
    "thumbnail_base64": null
  }
}
```

#### `ui.messageMetadata` — Collapsible sections

```json
{
  "jsonrpc": "2.0",
  "method": "ui.messageMetadata",
  "params": {
    "task_id": "task_abc123",
    "collapsible": true,
    "collapsible_title": "Thinking process",
    "auto_collapse": true
  }
}
```

#### `ui.requestHistory` — Request more context

```json
{
  "jsonrpc": "2.0",
  "method": "ui.requestHistory",
  "params": {
    "task_id": "task_abc123",
    "request_id": "hist_req_1a2b3c",
    "reason": "You mentioned a project from earlier, let me retrieve that context.",
    "requested_count": 40
  }
}
```

### 6.4 Directive syntax mode (for non-tool-calling agents)

If your LLM doesn't support function calling, use directive syntax. Inject the `acp_directive_prompt` (from `hub.getUIComponentTemplates`) into your system prompt. The LLM outputs directives like:

```
Here are your options:

<<<directive
{"type": "action_confirmation", "prompt": "What next?", "actions": [{"id": "a", "label": "Go", "style": "primary"}]}
>>>
```

Your agent parses these blocks and converts them to `ui.*` notifications:

```python
class ACPDirectiveStreamParser:
    """Parse <<<directive ... >>> blocks from LLM output."""
    _OPEN_FENCE = "<<<directive"
    _CLOSE_FENCE = ">>>"

    def feed(self, chunk: str) -> List[Union[ACPTextChunk, ACPDirective]]:
        # Returns text chunks and parsed directives
        ...

    def flush(self) -> List[...]:
        # Call when stream ends
        ...

# Usage in streaming loop:
parser = ACPDirectiveStreamParser(known_types=cached_known_types)
async for chunk in llm_stream:
    for event in parser.feed(chunk):
        if isinstance(event, ACPTextChunk):
            await ws.send_json(jsonrpc_notification("ui.textContent", {
                "task_id": task_id, "content": event.content, "is_final": False
            }))
        elif isinstance(event, ACPDirective):
            method = component_method_map.get(event.directive_type)
            if method:
                params = dict(event.payload)
                params["task_id"] = task_id
                await ws.send_json(jsonrpc_notification(method, params))
```

> See `agents/mac_agent/mac_agent.py` for the complete `ACPDirectiveStreamParser` implementation.

---

## 7. File Transfer

### 7.1 HTTP file serving (recommended)

The simplest approach: serve files over HTTP and send a `ui.fileMessage` notification with the URL.

```python
import os, uuid, time, mimetypes
from aiohttp import web

_served_files = {}  # file_id -> {path, filename, mime_type, size, created_at}

async def send_file_to_user(ws, task_id, file_path):
    """Register file for HTTP serving and notify the App."""
    file_id = uuid.uuid4().hex[:12]
    filename = os.path.basename(file_path)
    mime_type, _ = mimetypes.guess_type(file_path)
    size = os.path.getsize(file_path)

    _served_files[file_id] = {
        "path": file_path, "filename": filename,
        "mime_type": mime_type or "application/octet-stream",
        "size": size, "created_at": time.time(),
    }

    file_url = f"http://your-agent-host:8080/files/{file_id}"

    await ws.send_json({
        "jsonrpc": "2.0",
        "method": "ui.fileMessage",
        "params": {
            "task_id": task_id,
            "url": file_url,
            "filename": filename,
            "mime_type": mime_type or "application/octet-stream",
            "size": size,
        }
    })

async def handle_file_serve(request):
    """HTTP endpoint to serve registered files."""
    file_id = request.match_info.get("file_id", "")
    entry = _served_files.get(file_id)
    if not entry or not os.path.exists(entry["path"]):
        return web.Response(status=404, text="File not found")
    return web.FileResponse(entry["path"], headers={
        "Content-Type": entry["mime_type"],
        "Content-Disposition": f'inline; filename="{entry["filename"]}"',
    })

# Register the route:
# app.router.add_get("/files/{file_id}", handle_file_serve)
```

### 7.2 WebSocket binary transfer

For direct file transfer without HTTP, use binary WebSocket frames. The App may request file data via `agent.requestFileData`.

**Binary frame format:**

```
┌──────────┬───────────────┬─────────────────┐
│ 4 bytes  │ 12 bytes      │ Variable length │
│ "FILE"   │ file_id       │ Chunk data      │
│ (magic)  │ (null-padded) │                 │
└──────────┴───────────────┴─────────────────┘
```

**Transfer flow:**

```python
async def handle_request_file_data(self, ws, msg_id, params):
    file_id = params["file_id"]
    entry = get_served_file(file_id)
    chunk_size = 65536  # 64KB

    # 1. Send metadata response
    metadata = {
        "file_id": file_id, "filename": entry["filename"],
        "mime_type": entry["mime_type"], "size": entry["size"],
        "chunk_size": chunk_size,
        "chunk_count": math.ceil(entry["size"] / chunk_size),
    }
    await ws.send_json(jsonrpc_response(msg_id, result=metadata))

    # 2. Send file.transferStart notification
    await ws.send_json(jsonrpc_notification("file.transferStart", metadata))

    # 3. Stream binary frames
    magic = b"FILE"
    file_id_bytes = file_id.encode("utf-8")[:12]
    file_id_padded = file_id_bytes + b"\x00" * (12 - len(file_id_bytes))
    header = magic + file_id_padded

    with open(entry["path"], "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            await ws.send_bytes(header + chunk)

    # 4. Send file.transferComplete notification
    await ws.send_json(jsonrpc_notification("file.transferComplete", {
        "file_id": file_id, "total_bytes": entry["size"],
    }))
```

---

## 8. Conversation History Management

### 8.1 Session-based history

The App manages conversations by `session_id`. When sending `agent.chat`, the App may include:

- `history` — Full conversation history (for new/cold sessions)
- `total_message_count` — How many messages exist in the App (for gap detection)

Your agent should:

1. **Check if session exists locally**. If not, initialize from the `history` array.
2. **Compare** `total_message_count` with your local message count to detect gaps.
3. **Trim history** to avoid exceeding LLM context windows.

```python
class ConversationManager:
    def __init__(self, max_history=20):
        self.max_history = max_history
        self._sessions = {}  # session_id -> [{"role": ..., "content": ...}]

    def add_user_message(self, session_id, content):
        self._ensure_session(session_id)
        self._sessions[session_id].append({"role": "user", "content": content})
        self._trim(session_id)

    def add_assistant_message(self, session_id, content):
        self._ensure_session(session_id)
        self._sessions[session_id].append({"role": "assistant", "content": content})
        self._trim(session_id)

    def initialize_session(self, session_id, history):
        if session_id not in self._sessions:
            self._sessions[session_id] = list(history)

    def rollback(self, session_id):
        msgs = self._sessions.get(session_id, [])
        if msgs and msgs[-1]["role"] == "assistant":
            msgs.pop()
        if msgs and msgs[-1]["role"] == "user":
            msgs.pop()

    def _trim(self, session_id):
        msgs = self._sessions[session_id]
        max_msgs = self.max_history * 2
        if len(msgs) > max_msgs:
            self._sessions[session_id] = msgs[-max_msgs:]
```

### 8.2 History supplement flow

When the agent requests more history (via `ui.requestHistory`), the App sends a follow-up `agent.chat` with:

```json
{
  "history_supplement": true,
  "additional_history": [ ... older messages ... ],
  "original_question": "the user's original question"
}
```

Handle it by prepending the older messages and re-generating the response:

```python
if params.get("history_supplement"):
    additional = params.get("additional_history", [])
    if additional:
        conv_mgr.prepend_history(session_id, additional)

    # Remove incomplete assistant reply
    msgs = conv_mgr.get_messages(session_id)
    if msgs and msgs[-1]["role"] == "assistant":
        msgs.pop()

    # Re-process with enriched context (don't add a new user message)
    messages = conv_mgr.get_messages(session_id)
else:
    conv_mgr.add_user_message(session_id, message)
    messages = conv_mgr.get_messages(session_id)
```

---

## 9. Complete Example (Raw Protocol)

A production-ready agent skeleton combining all features:

```python
#!/usr/bin/env python3
"""Production-ready ACP Agent skeleton with all features."""

import asyncio, json, uuid, math, os, time, mimetypes
from datetime import datetime
from aiohttp import web
import aiohttp

# ===== JSON-RPC helpers =====

def rpc_response(id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id}
    msg["error"] = error if error else {"result": result or {}}  # Simplified
    if error:
        msg["error"] = error
    else:
        msg["result"] = result if result is not None else {}
    return msg

def rpc_notify(method, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params:
        msg["params"] = params
    return msg

def rpc_request(method, params=None):
    return {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": str(uuid.uuid4())}

# ===== Conversation Manager =====

class ConversationManager:
    def __init__(self, max_history=20):
        self._sessions, self._max = {}, max_history
    def get(self, sid): return self._sessions.get(sid, [])
    def has(self, sid): return sid in self._sessions
    def init(self, sid, history):
        if sid not in self._sessions: self._sessions[sid] = list(history)
    def add_user(self, sid, content):
        self._sessions.setdefault(sid, []).append({"role": "user", "content": content})
        self._trim(sid)
    def add_assistant(self, sid, content):
        self._sessions.setdefault(sid, []).append({"role": "assistant", "content": content})
        self._trim(sid)
    def prepend(self, sid, older):
        if sid in self._sessions: self._sessions[sid] = older + self._sessions[sid]
    def rollback(self, sid):
        msgs = self._sessions.get(sid, [])
        if msgs and msgs[-1]["role"] == "assistant": msgs.pop()
        if msgs and msgs[-1]["role"] == "user": msgs.pop()
    def _trim(self, sid):
        m = self._sessions[sid]
        if len(m) > self._max * 2: self._sessions[sid] = m[-(self._max * 2):]

# ===== Agent Server =====

class MyAgent:
    def __init__(self, token="", port=8080):
        self.token = token
        self.port = port
        self.conv = ConversationManager()
        self._tasks = {}
        self._pending = {}  # For hub.* request/response tracking

    async def ws_handler(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        authed = False

        async for msg in ws:
            if msg.type == aiohttp.WSMsgType.TEXT:
                data = json.loads(msg.data)
                method, mid, params = data.get("method"), data.get("id"), data.get("params", {})

                # --- Requests from App (has id + method) ---
                if mid is not None and method is not None:
                    if method == "auth.authenticate":
                        if not self.token or params.get("token") == self.token:
                            authed = True
                            await ws.send_json(rpc_response(mid, {"status": "authenticated"}))
                        else:
                            await ws.send_json(rpc_response(mid, error={"code": -32000, "message": "Auth failed"}))

                    elif method == "ping":
                        await ws.send_json(rpc_response(mid, {"pong": True}))

                    elif not authed:
                        await ws.send_json(rpc_response(mid, error={"code": -32000, "message": "Not authenticated"}))

                    elif method == "agent.chat":
                        task = asyncio.create_task(self._handle_chat(ws, mid, params))
                        self._tasks[params.get("task_id", "")] = task

                    elif method == "agent.cancelTask":
                        t = self._tasks.pop(params.get("task_id", ""), None)
                        if t: t.cancel()
                        await ws.send_json(rpc_response(mid, {"status": "cancelled"}))

                    elif method == "agent.submitResponse":
                        await ws.send_json(rpc_response(mid, {"status": "received"}))
                        # Resolve pending UI component futures here if needed
                        rd = params.get("response_data", {})
                        for key in ("confirmation_id", "select_id", "upload_id", "form_id"):
                            cid = rd.get(key)
                            if cid:
                                fut = self._pending.pop(cid, None)
                                if fut and not fut.done(): fut.set_result(rd)

                    elif method == "agent.rollback":
                        self.conv.rollback(params.get("session_id", ""))
                        await ws.send_json(rpc_response(mid, {"status": "ok"}))

                    elif method == "agent.getCard":
                        await ws.send_json(rpc_response(mid, {
                            "agent_id": "my-agent", "name": "My Agent",
                            "description": "A production ACP agent", "version": "1.0.0",
                            "capabilities": ["chat", "streaming", "interactive_messages"],
                            "supported_protocols": ["acp"],
                        }))

                # --- Responses to OUR requests (has id, no method) ---
                elif mid is not None and method is None:
                    fut = self._pending.pop(mid, None)
                    if fut and not fut.done():
                        if data.get("error"):
                            fut.set_exception(RuntimeError(str(data["error"])))
                        else:
                            fut.set_result(data.get("result"))

        # Cleanup on disconnect
        for t in self._tasks.values(): t.cancel()
        self._tasks.clear()
        return ws

    async def _handle_chat(self, ws, mid, params):
        task_id = params.get("task_id", str(uuid.uuid4()))
        session_id = params.get("session_id", task_id)
        message = params.get("message", "")

        # Acknowledge
        await ws.send_json(rpc_response(mid, {"task_id": task_id, "status": "accepted"}))
        await ws.send_json(rpc_notify("task.started", {"task_id": task_id, "started_at": datetime.now().isoformat()}))

        # Restore history
        if not self.conv.has(session_id) and params.get("history"):
            valid = [{"role": m["role"], "content": m["content"]}
                     for m in params["history"]
                     if m.get("role") in ("user", "assistant") and m.get("content")]
            self.conv.init(session_id, valid)

        # Handle history supplement
        if params.get("history_supplement"):
            additional = params.get("additional_history", [])
            if additional:
                valid = [{"role": m["role"], "content": m["content"]}
                         for m in additional if m.get("role") in ("user", "assistant") and m.get("content")]
                self.conv.prepend(session_id, valid)
            msgs = self.conv.get(session_id)
            if msgs and msgs[-1]["role"] == "assistant": msgs.pop()
        else:
            self.conv.add_user(session_id, message)

        messages = self.conv.get(session_id)

        try:
            # ====================================================
            # YOUR LLM / BUSINESS LOGIC HERE
            # Replace this with your actual agent implementation
            # ====================================================
            reply = f"Received: {message}"
            for i in range(0, len(reply), 10):
                await ws.send_json(rpc_notify("ui.textContent", {
                    "task_id": task_id, "content": reply[i:i+10], "is_final": False
                }))
                await asyncio.sleep(0.02)

            # Final text + task completed
            await ws.send_json(rpc_notify("ui.textContent", {"task_id": task_id, "content": "", "is_final": True}))
            self.conv.add_assistant(session_id, reply)
            await ws.send_json(rpc_notify("task.completed", {
                "task_id": task_id, "status": "success", "completed_at": datetime.now().isoformat()
            }))

        except asyncio.CancelledError:
            await ws.send_json(rpc_notify("task.error", {"task_id": task_id, "message": "Cancelled", "code": -32008}))
        except Exception as e:
            await ws.send_json(rpc_notify("task.error", {"task_id": task_id, "message": str(e), "code": -32603}))
        finally:
            self._tasks.pop(task_id, None)

    async def _hub_request(self, ws, method, params=None, timeout=10.0):
        """Send a request TO the App and wait for response."""
        req_id = str(uuid.uuid4())
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        self._pending[req_id] = future
        await ws.send_json(rpc_request(method, params) | {"id": req_id})
        return await asyncio.wait_for(future, timeout=timeout)

# ===== Main =====

def create_app():
    agent = MyAgent(token=os.getenv("AGENT_TOKEN", ""), port=8080)
    app = web.Application()
    app.router.add_get("/acp/ws", agent.ws_handler)
    return app

if __name__ == "__main__":
    web.run_app(create_app(), host="0.0.0.0", port=8080)
```

---

## 10. Error Codes Reference

### JSON-RPC standard errors

| Code | Name | Description |
|------|------|-------------|
| `-32700` | Parse error | Invalid JSON received |
| `-32600` | Invalid request | JSON is not a valid JSON-RPC request |
| `-32601` | Method not found | Requested method does not exist |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Generic server error |

### Application-level errors

| Code | Name | Description |
|------|------|-------------|
| `-32000` | Authentication failed | Token is invalid or missing |
| `-32001` | Unauthorized | Authenticated but not authorized for this action |
| `-32002` | Permission denied | Specific permission not granted |
| `-32003` | Not found | Resource (task, file, session) not found |
| `-32004` | Pending approval | Action requires user approval |
| `-32005` | Session not found | Conversation session does not exist |
| `-32006` | Task failed | Task execution failed |
| `-32007` | Timeout | Operation timed out |
| `-32008` | Task cancelled | Task was cancelled by user |

---

## 11. FAQ

### Q: What's the minimum I need to implement?

Handle these 3 methods and you have a working agent:
1. `auth.authenticate` — return success
2. `ping` — return pong
3. `agent.chat` — acknowledge, send `task.started`, stream `ui.textContent`, send `is_final=true`, send `task.completed`

### Q: Do I need to implement all UI components?

No. UI components are entirely optional. A text-only agent that just streams `ui.textContent` works perfectly. Add UI components incrementally as needed.

### Q: How does the App discover my agent?

Users manually add your agent in the App's settings by providing the WebSocket URL and authentication token. There is no automatic discovery.

### Q: Can I use languages other than Python?

Yes. The protocol is language-agnostic — any WebSocket server that speaks JSON-RPC 2.0 will work. The Python examples are for reference only.

### Q: How do I handle concurrent chat requests?

Spawn each `agent.chat` handler as an async task, keyed by `task_id`. This allows:
- Multiple conversations simultaneously
- Cancellation of individual tasks via `agent.cancelTask`

```python
task = asyncio.create_task(self._handle_chat(ws, msg_id, params))
self._active_tasks[task_id] = task
```

### Q: What happens when the WebSocket disconnects?

The App has auto-reconnect with exponential backoff (up to 5 attempts). Your agent should:
- Cancel all active tasks on disconnect
- Clean up pending request futures
- Accept new connections without state assumptions

### Q: How do I test my agent without the App?

Use `wscat` or a Python WebSocket client:

```bash
# Install wscat
npm install -g wscat

# Connect
wscat -c ws://localhost:8080/acp/ws

# Send auth
> {"jsonrpc":"2.0","method":"auth.authenticate","params":{"token":"my-token"},"id":1}

# Send chat
> {"jsonrpc":"2.0","method":"agent.chat","params":{"task_id":"test1","session_id":"s1","message":"Hello","user_id":"u1","message_id":"m1"},"id":2}
```

### Q: How should I handle the `history` vs local session state?

1. On first contact for a session, use the `history` array to bootstrap
2. Subsequent messages within the same WebSocket session use your local state
3. If `total_message_count` > your local count, you may be missing context — consider requesting more via `ui.requestHistory`

### Q: What's the `ui_component_version` field for?

It's a version string for the App's UI component registry. If it changes between requests, re-fetch component templates via `hub.getUIComponentTemplates` to get updated schemas and prompts.

---

## Appendix: Reference implementations

### Python SDK (recommended for new agents)

```
agents/paw_acp_sdk/
├── paw_acp_sdk/        # Reusable SDK package
│   ├── server.py       # ACPAgentServer base class
│   ├── task_context.py # TaskContext per-task helper
│   ├── providers.py    # OpenAIProvider, ClaudeProvider, GLMProvider
│   └── ...
└── examples/
    ├── echo_agent.py           # Minimal agent (~20 lines)
    └── llm_agent_example.py    # LLM agent with streaming (~50 lines)
```

### Production reference (mac_agent)

For a full production implementation covering tool calling, file transfer, UI components, and risk classification:

```
agents/mac_agent/
├── mac_agent.py    # ACP WebSocket server with full protocol implementation
├── llm_agent.py    # LLM providers (OpenAI, Claude, GLM) + conversation management
├── mac_tools.py    # Tool definitions, risk classification, and execution
└── README.md
```

Key classes to study:
- `ACPAgentServer` in `mac_agent.py` — Complete WebSocket handler
- `ACPDirectiveStreamParser` in `mac_agent.py` — Directive syntax parser
- `ConversationManager` in `llm_agent.py` — Session history management
- `LLMProvider` / `OpenAIProvider` / `ClaudeProvider` in `llm_agent.py` — LLM integration patterns

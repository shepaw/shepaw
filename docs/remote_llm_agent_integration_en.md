# Shepaw Remote LLM Agent Integration Guide

> For third-party developers who want to connect their own LLM / AI Agent to Shepaw
>
> Protocol version: ACP 1.0 | Last updated: 2026-03-22

> **Language:** [中文](remote_llm_agent_integration.md) | **English**

---

## Table of Contents

1. [Overview](#1-overview)
2. [Quick Start](#2-quick-start)
3. [Protocol Specification](#3-protocol-specification)
4. [Connection & Authentication](#4-connection--authentication)
5. [Core Message Flow: agent.chat](#5-core-message-flow-agentchat)
6. [Attachments & Multimodal Support](#6-attachments--multimodal-support)
7. [UI Interactive Components](#7-ui-interactive-components)
8. [File Transfer](#8-file-transfer)
9. [Task Lifecycle Management](#9-task-lifecycle-management)
10. [Conversation History Management](#10-conversation-history-management)
11. [Hub Data Queries (Agent → App)](#11-hub-data-queries-agent--app)
12. [Group Chat Support](#12-group-chat-support)
13. [Complete Implementation Example](#13-complete-implementation-example)
14. [Error Code Reference](#14-error-code-reference)
15. [Registering Your Agent in Shepaw](#15-registering-your-agent-in-shepaw)
16. [FAQ](#16-faq)

---

## 1. Overview

### 1.1 Architecture

Shepaw uses the **ACP (Agent Communication Protocol)** to communicate with Remote Agents. ACP is built on **JSON-RPC 2.0 over WebSocket**, supporting full bidirectional messaging.

```
┌──────────────────────┐         WebSocket (JSON-RPC 2.0)         ┌──────────────────────┐
│                      │ ──────────────────────────────────────► │                      │
│   Shepaw (App)       │    App→Agent: agent.chat, agent.cancel   │   Your Remote Agent  │
│   (Flutter client)   │   Agent→App: ui.textContent, task.*      │   (Python / any lang)│
│                      │ ◄──────────────────────────────────────  │                      │
└──────────────────────┘   Agent→App: hub.* requests              └──────────────────────┘
```

### 1.2 What Your Agent Needs to Do

**Required (minimum viable agent):**

1. Start a WebSocket server listening at a `/acp/ws` endpoint
2. Handle `auth.authenticate` authentication
3. Handle `agent.chat` and stream responses back via `ui.textContent`
4. Send `task.started` / `task.completed` / `task.error` lifecycle events
5. Respond to `ping` heartbeats

**Optional:**

- Send rich interactive UI components (buttons, forms, selectors)
- Receive and process user-uploaded attachments (images, files, audio)
- Query App session data via `hub.*` methods
- Deliver files to users via HTTP or WebSocket binary frames
- Support group chat scenarios

### 1.3 Communication Modes Overview

| Direction | Type | Methods |
|-----------|------|---------|
| App → Agent | Request | `auth.authenticate`, `agent.chat`, `agent.cancelTask`, `agent.submitResponse`, `agent.rollback`, `agent.getCard`, `ping` |
| Agent → App | Notification | `ui.textContent`, `ui.actionConfirmation`, `ui.singleSelect`, `ui.multiSelect`, `ui.fileUpload`, `ui.form`, `ui.fileMessage`, `ui.messageMetadata`, `ui.requestHistory` |
| Agent → App | Task events | `task.started`, `task.completed`, `task.error` |
| Agent → App | Request | `hub.getUIComponentTemplates`, `hub.getSessions`, `hub.getSessionMessages`, `hub.getAgentList`, `hub.getHubInfo`, `hub.getAttachmentContent`, `hub.initiateChat` |
| Bidirectional | Heartbeat | `ping` / `pong` |

---

## 2. Quick Start

Here is the smallest possible working Python Agent — about 70 lines:

```python
#!/usr/bin/env python3
"""Shepaw ACP minimal agent example"""

import asyncio
import json
import uuid
from datetime import datetime
from aiohttp import web

def rpc_ok(id, result=None):
    return {"jsonrpc": "2.0", "id": id, "result": result or {}}

def rpc_err(id, code, message):
    return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

def notify(method, params):
    return {"jsonrpc": "2.0", "method": method, "params": params}

async def ws_handler(request):
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    authed = False

    async for msg in ws:
        if msg.type != web.WSMsgType.TEXT:
            continue

        data = json.loads(msg.data)
        method = data.get("method")
        mid = data.get("id")
        params = data.get("params", {})

        if method == "auth.authenticate":
            if params.get("token") == "my-secret-token":
                authed = True
                await ws.send_json(rpc_ok(mid, {"status": "authenticated"}))
            else:
                await ws.send_json(rpc_err(mid, -32000, "Auth failed"))

        elif method == "ping":
            await ws.send_json(rpc_ok(mid, {"pong": True}))

        elif not authed:
            await ws.send_json(rpc_err(mid, -32001, "Not authenticated"))

        elif method == "agent.chat":
            task_id = params["task_id"]
            message = params.get("message", "")

            # 1. Acknowledge immediately
            await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "accepted"}))
            # 2. Task started
            await ws.send_json(notify("task.started", {
                "task_id": task_id, "started_at": datetime.now().isoformat()
            }))
            # 3. Stream reply (replace with your own LLM call)
            reply = f"You said: {message}"
            for chunk in [reply[i:i+5] for i in range(0, len(reply), 5)]:
                await ws.send_json(notify("ui.textContent", {
                    "task_id": task_id, "content": chunk, "is_final": False
                }))
                await asyncio.sleep(0.05)
            # 4. Final text marker (required)
            await ws.send_json(notify("ui.textContent", {
                "task_id": task_id, "content": "", "is_final": True
            }))
            # 5. Task completed
            await ws.send_json(notify("task.completed", {
                "task_id": task_id, "status": "success",
                "completed_at": datetime.now().isoformat()
            }))

        elif method == "agent.getCard":
            await ws.send_json(rpc_ok(mid, {
                "agent_id": "my-llm-agent",
                "name": "My LLM Agent",
                "description": "A simple LLM agent example",
                "version": "1.0.0",
                "capabilities": ["chat", "streaming"],
                "supported_protocols": ["acp"],
            }))

    return ws

app = web.Application()
app.router.add_get("/acp/ws", ws_handler)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=8080)
```

**Start and register:**

```bash
pip install aiohttp
python my_agent.py
# In Shepaw App, add a Remote Agent:
#   Address: ws://<your-ip>:8080/acp/ws
#   Token: my-secret-token
```

---

## 3. Protocol Specification

### 3.1 Transport

| Property | Value |
|----------|-------|
| Protocol | WebSocket (RFC 6455) |
| Endpoint | `ws://<host>:<port>/acp/ws` (path is customizable) |
| Encoding | UTF-8 JSON text frames |
| Binary frames | Used for file transfer only (see Section 8) |
| Port | No fixed requirement — choose your own |

### 3.2 JSON-RPC 2.0 Message Types

ACP uses standard JSON-RPC 2.0 format. Distinguish message types by the presence of `id` and `method` fields:

**Request** (has both `id` and `method`):
```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "params": { "task_id": "...", "message": "Hello" },
  "id": 1
}
```

**Response** (has `id`, no `method`):
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "task_id": "...", "status": "accepted" }
}
```

**Error Response**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32000, "message": "Authentication failed" }
}
```

**Notification** (has `method`, no `id`):
```json
{
  "jsonrpc": "2.0",
  "method": "ui.textContent",
  "params": { "task_id": "...", "content": "Hello", "is_final": false }
}
```

> **Key rule**: The same WebSocket connection carries both request/response pairs and fire-and-forget notifications in both directions. When parsing a message, check whether `id` and `method` are present to determine the message type.

---

## 4. Connection & Authentication

### 4.1 Connection Establishment

The App connects to your Agent's WebSocket endpoint on startup. Once connected, it immediately sends an authentication request.

Your server does not need any special handling at the HTTP upgrade stage — just accept a standard WebSocket connection.

### 4.2 Authentication Handshake

The first message after connection is `auth.authenticate`:

```json
// App sends
{
  "jsonrpc": "2.0",
  "method": "auth.authenticate",
  "params": { "token": "your-agent-token" },
  "id": 1
}

// Success
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "status": "authenticated" }
}

// Failure
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32000, "message": "Authentication failed" }
}
```

**Note**: On failure you may keep the connection open and wait for a retry, or close it immediately. Before authentication succeeds, reject all requests except `ping`.

### 4.3 Heartbeat

The App sends `ping` every **30 seconds**. You must reply with `pong`:

```json
// App sends
{ "jsonrpc": "2.0", "method": "ping", "params": {}, "id": 2 }

// Agent replies
{ "jsonrpc": "2.0", "id": 2, "result": { "pong": true } }
```

> **Note**: Three consecutive unanswered pings will cause the App to disconnect and attempt reconnection (up to 5 attempts, exponential backoff).

---

## 5. Core Message Flow: agent.chat

### 5.1 Request Format

```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "id": 3,
  "params": {
    "task_id": "task_abc123",
    "session_id": "session_xyz",
    "message": "Help me analyze this data",
    "user_id": "user_001",
    "message_id": "msg_001",
    "history": [
      { "role": "user", "content": "Hello" },
      { "role": "assistant", "content": "Hi! How can I help you?" }
    ],
    "total_message_count": 10,
    "ui_component_version": "1.0.0",
    "system_prompt": null,
    "group_context": null,
    "attachments": null
  }
}
```

**Parameter reference:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `task_id` | string | Yes | Unique task ID for this request, used to track the entire response stream |
| `session_id` | string | Yes | Session/conversation ID for context management |
| `message` | string | Yes* | User message text (may be empty when attachments are present) |
| `user_id` | string | Yes | ID of the user who sent the message |
| `message_id` | string | Yes | Unique ID of this specific message |
| `history` | array | No | Conversation history (sent for new sessions or history sync) |
| `total_message_count` | int | No | Total messages in the App's session — use for gap detection |
| `ui_component_version` | string | No | App UI component registry version; re-fetch templates when this changes |
| `history_supplement` | bool | No | `true` when this is a history supplement request (see Section 10) |
| `additional_history` | array | No | Older history messages to prepend |
| `original_question` | string | No | Original user question in history supplement scenarios |
| `system_prompt` | string | No | System prompt override (used in group chat, etc.) |
| `group_context` | object | No | Group chat metadata (see Section 12) |
| `attachments` | array | No | User attachment list (see Section 6) |

### 5.2 Standard Response Sequence

After receiving `agent.chat`, respond strictly in this order:

```
┌──────────────────────────────────────────────────────────────┐
│  Step 1: Send JSON-RPC response immediately (acknowledge)     │
│  Step 2: Send task.started notification                       │
│  Step 3: Send multiple ui.textContent notifications (stream)  │
│  Step 4: Send ui.textContent with is_final=true               │
│  Step 5: Send task.completed notification                     │
└──────────────────────────────────────────────────────────────┘
```

```python
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]

    # Step 1: Acknowledge immediately (do NOT wait for LLM response)
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {"task_id": task_id, "status": "accepted"}
    })

    # Step 2: Task started
    await ws.send_json({
        "jsonrpc": "2.0", "method": "task.started",
        "params": {"task_id": task_id, "started_at": datetime.now().isoformat()}
    })

    # Step 3: Stream text (call your LLM here)
    async for chunk in call_your_llm(params["message"]):
        await ws.send_json({
            "jsonrpc": "2.0", "method": "ui.textContent",
            "params": {"task_id": task_id, "content": chunk, "is_final": False}
        })

    # Step 4: Mark stream as complete (REQUIRED — App relies on this to close the bubble)
    await ws.send_json({
        "jsonrpc": "2.0", "method": "ui.textContent",
        "params": {"task_id": task_id, "content": "", "is_final": True}
    })

    # Step 5: Task completed
    await ws.send_json({
        "jsonrpc": "2.0", "method": "task.completed",
        "params": {"task_id": task_id, "status": "success",
                   "completed_at": datetime.now().isoformat()}
    })
```

> **Important**: The `is_final=true` `ui.textContent` message is **mandatory**. The App uses this signal to finalize the message bubble. Omitting it will leave the message stuck in a "loading" state until it times out.

### 5.3 history Array Format

Each entry in the `history` array:

```json
[
  { "role": "user", "content": "Hello" },
  { "role": "assistant", "content": "Hi! How can I help?" },
  { "role": "user", "content": "Write me a poem" },
  { "role": "assistant", "content": "Here is a poem for you..." }
]
```

- `role`: `"user"` or `"assistant"`
- `content`: message text (string)

---

## 6. Attachments & Multimodal Support

### 6.1 Attachment Data Format

When a user sends images, files, or audio, the `attachments` field in `agent.chat` contains a list of attachments:

```json
{
  "attachments": [
    {
      "file_name": "photo.jpg",
      "mime_type": "image/jpeg",
      "size": 204800,
      "data": "base64-encoded content...",
      "type": "image",
      "extra": null
    },
    {
      "file_name": "document.pdf",
      "mime_type": "application/pdf",
      "size": 1048576,
      "data": "base64-encoded content...",
      "type": "document",
      "extra": null
    },
    {
      "file_name": "voice_message.m4a",
      "mime_type": "audio/m4a",
      "size": 51200,
      "data": "base64-encoded content...",
      "type": "audio",
      "extra": {
        "duration_ms": 5000
      }
    }
  ]
}
```

**Attachment fields:**

| Field | Type | Description |
|-------|------|-------------|
| `file_name` | string | Original file name |
| `mime_type` | string | File MIME type |
| `size` | int | File size in bytes |
| `data` | string | Base64-encoded file content |
| `type` | string | Semantic type: `image`, `audio`, `video`, `document`, or `file` |
| `extra` | object/null | Extra metadata, e.g. `duration_ms` (milliseconds) for audio |

**Size limit**: Each attachment is capped at **20 MB**.

### 6.2 Processing Attachments

```python
import base64

async def handle_chat_with_attachments(ws, msg_id, params):
    task_id = params["task_id"]
    message = params.get("message", "")
    attachments = params.get("attachments") or []

    images = []
    files = []
    for att in attachments:
        att_type = att.get("type", "file")
        att_bytes = base64.b64decode(att["data"])

        if att_type == "image":
            images.append({
                "name": att["file_name"],
                "mime_type": att["mime_type"],
                "bytes": att_bytes
            })
        elif att_type == "audio":
            duration_ms = (att.get("extra") or {}).get("duration_ms", 0)
            files.append({
                "name": att["file_name"],
                "type": "audio",
                "duration_sec": duration_ms / 1000,
                "bytes": att_bytes
            })
        else:
            files.append({
                "name": att["file_name"],
                "mime_type": att["mime_type"],
                "bytes": att_bytes
            })

    # Build messages for multimodal LLM (OpenAI vision format example)
    user_content = []
    if message:
        user_content.append({"type": "text", "text": message})

    for img in images:
        b64 = base64.b64encode(img["bytes"]).decode()
        user_content.append({
            "type": "image_url",
            "image_url": {"url": f"data:{img['mime_type']};base64,{b64}"}
        })

    # Call multimodal LLM...
```

---

## 7. UI Interactive Components

Your Agent can embed rich interactive widgets in the chat. There are two ways to send them:

### 7.1 Two Sending Modes

| Mode | When to use | How it works |
|------|-------------|-------------|
| **Directive syntax** | LLMs without Function Calling | LLM embeds `<<<directive ... >>>` blocks in text; you parse and convert to `ui.*` notifications |
| **Tool Calling** | LLMs with Function Calling | LLM calls UI component functions directly; you convert tool calls to `ui.*` notifications |

Both modes ultimately send the same `ui.*` JSON-RPC notifications to the App.

### 7.2 Fetching Component Definitions Dynamically

Before sending UI components, fetch the current component templates via `hub.getUIComponentTemplates`:

```python
async def fetch_ui_templates(ws, pending_requests):
    """Fetch UI component templates from the App (call once on startup and cache)."""
    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    pending_requests[req_id] = future

    await ws.send_json({
        "jsonrpc": "2.0",
        "method": "hub.getUIComponentTemplates",
        "id": req_id
    })

    result = await asyncio.wait_for(future, timeout=10.0)

    return {
        "version": result["version"],
        # Directive mode: inject into system prompt
        "directive_prompt": result["prompt_templates"]["acp_directive_prompt"],
        # Tool Calling mode: merge into your tool list
        "openai_tools": result["schemas"]["openai_tools"],
        "claude_tools": result["schemas"]["claude_tools"],
        # Method map: component type name -> ACP notification method
        "method_map": {
            c["name"]: c["acp_notification_method"]
            for c in result["components"]
        }
    }
```

### 7.3 Notification Message Formats

#### `ui.textContent` — Streaming text

```json
// Streaming chunk
{
  "jsonrpc": "2.0", "method": "ui.textContent",
  "params": { "task_id": "task_abc123", "content": "Analyzing...", "is_final": false }
}

// End marker (REQUIRED)
{
  "jsonrpc": "2.0", "method": "ui.textContent",
  "params": { "task_id": "task_abc123", "content": "", "is_final": true }
}
```

#### `ui.actionConfirmation` — Action buttons

```json
{
  "jsonrpc": "2.0", "method": "ui.actionConfirmation",
  "params": {
    "task_id": "task_abc123",
    "confirmation_id": "confirm_1a2b3c",
    "prompt": "Proceed with this operation?",
    "actions": [
      { "id": "approve", "label": "Confirm", "style": "primary" },
      { "id": "modify", "label": "Modify", "style": "secondary" },
      { "id": "cancel", "label": "Cancel", "style": "danger" }
    ]
  }
}
```

Button styles: `"primary"` (main action), `"secondary"` (alternative), `"danger"` (destructive/cancel)

After the user clicks, the App returns the result via `agent.submitResponse`:
```json
{
  "response_type": "action_confirmation",
  "response_data": { "confirmation_id": "confirm_1a2b3c", "selected_action_id": "approve" }
}
```

#### `ui.singleSelect` — Single-choice list

```json
{
  "jsonrpc": "2.0", "method": "ui.singleSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "select_1a2b3c",
    "prompt": "Choose a deployment environment:",
    "options": [
      { "id": "dev", "label": "Development" },
      { "id": "staging", "label": "Staging" },
      { "id": "prod", "label": "Production" }
    ]
  }
}
```

#### `ui.multiSelect` — Multi-choice list

```json
{
  "jsonrpc": "2.0", "method": "ui.multiSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "mselect_1a2b3c",
    "prompt": "Select features to enable:",
    "options": [
      { "id": "feature_a", "label": "Feature A" },
      { "id": "feature_b", "label": "Feature B" },
      { "id": "feature_c", "label": "Feature C" }
    ],
    "min_select": 1,
    "max_select": null
  }
}
```

`min_select`: minimum required selections (default 1); `max_select`: maximum allowed (null = unlimited)

#### `ui.fileUpload` — Request user file upload

```json
{
  "jsonrpc": "2.0", "method": "ui.fileUpload",
  "params": {
    "task_id": "task_abc123",
    "upload_id": "upload_1a2b3c",
    "prompt": "Please upload the documents to analyze:",
    "accept_types": ["pdf", "doc", "docx", "txt"],
    "max_files": 3,
    "max_size_mb": 20
  }
}
```

#### `ui.form` — Structured form

```json
{
  "jsonrpc": "2.0", "method": "ui.form",
  "params": {
    "task_id": "task_abc123",
    "form_id": "form_1a2b3c",
    "title": "New Task",
    "description": "Fill in the task details",
    "fields": [
      {
        "field_id": "title",
        "type": "text_input",
        "label": "Task Name",
        "placeholder": "Enter task name...",
        "required": true,
        "max_lines": 1
      },
      {
        "field_id": "priority",
        "type": "single_select",
        "label": "Priority",
        "required": true,
        "options": [
          { "id": "high", "label": "High" },
          { "id": "medium", "label": "Medium" },
          { "id": "low", "label": "Low" }
        ]
      },
      {
        "field_id": "tags",
        "type": "multi_select",
        "label": "Tags",
        "required": false,
        "options": [
          { "id": "bug", "label": "Bug" },
          { "id": "feature", "label": "Feature" },
          { "id": "docs", "label": "Documentation" }
        ]
      },
      {
        "field_id": "description",
        "type": "text_input",
        "label": "Description",
        "placeholder": "Describe the task...",
        "required": false,
        "max_lines": 5
      },
      {
        "field_id": "attachment",
        "type": "file_upload",
        "label": "Attachments",
        "required": false,
        "accept_types": ["png", "jpg", "pdf"],
        "max_files": 2,
        "max_size_mb": 10
      }
    ]
  }
}
```

**Form field types**: `"text_input"`, `"single_select"`, `"multi_select"`, `"file_upload"`

#### `ui.fileMessage` — Send a file to the user

```json
{
  "jsonrpc": "2.0", "method": "ui.fileMessage",
  "params": {
    "task_id": "task_abc123",
    "url": "http://your-agent:8080/files/abc123",
    "filename": "analysis_report.pdf",
    "mime_type": "application/pdf",
    "size": 204800,
    "thumbnail_base64": null
  }
}
```

#### `ui.messageMetadata` — Collapsible content

```json
{
  "jsonrpc": "2.0", "method": "ui.messageMetadata",
  "params": {
    "task_id": "task_abc123",
    "collapsible": true,
    "collapsible_title": "Reasoning process",
    "auto_collapse": true
  }
}
```

When used, the text body of the current response becomes the collapsible content, with `collapsible_title` shown as the section header.

#### `ui.requestHistory` — Request more history

```json
{
  "jsonrpc": "2.0", "method": "ui.requestHistory",
  "params": {
    "task_id": "task_abc123",
    "request_id": "hist_req_1a2b3c",
    "reason": "You mentioned a project we discussed earlier, but I don't have that context. Let me fetch more history.",
    "requested_count": 40
  }
}
```

> After sending this notification, stop generating text. The App will deliver a new `agent.chat` request containing the supplemental history (see Section 10).

### 7.4 Directive Syntax Mode (for non-tool-calling agents)

If your LLM does not support Function Calling, use directive syntax. Inject the `acp_directive_prompt` (from `hub.getUIComponentTemplates`) into your system prompt. The LLM will embed blocks like this in its output:

```
Here are your options:

<<<directive
{
  "type": "action_confirmation",
  "prompt": "How would you like to proceed?",
  "actions": [
    {"id": "yes", "label": "Continue", "style": "primary"},
    {"id": "no", "label": "Cancel", "style": "danger"}
  ]
}
>>>

Let me know if you need help with any of the options.
```

**Parser implementation (Python):**

```python
class DirectiveStreamParser:
    """Parse <<<directive ... >>> blocks from LLM streaming output."""

    OPEN = "<<<directive"
    CLOSE = ">>>"

    def __init__(self):
        self._buffer = ""
        self._in_directive = False
        self._directive_buffer = ""

    def feed(self, chunk: str) -> list:
        """Process a text chunk; returns a list of (type, data) events."""
        events = []
        self._buffer += chunk

        while True:
            if not self._in_directive:
                idx = self._buffer.find(self.OPEN)
                if idx == -1:
                    safe_len = max(0, len(self._buffer) - len(self.OPEN))
                    if safe_len > 0:
                        events.append(("text", self._buffer[:safe_len]))
                        self._buffer = self._buffer[safe_len:]
                    break
                else:
                    if idx > 0:
                        events.append(("text", self._buffer[:idx]))
                    self._buffer = self._buffer[idx + len(self.OPEN):]
                    self._in_directive = True
                    self._directive_buffer = ""
            else:
                idx = self._buffer.find(self.CLOSE)
                if idx == -1:
                    self._directive_buffer += self._buffer
                    self._buffer = ""
                    break
                else:
                    self._directive_buffer += self._buffer[:idx]
                    self._buffer = self._buffer[idx + len(self.CLOSE):]
                    self._in_directive = False
                    try:
                        directive = json.loads(self._directive_buffer.strip())
                        events.append(("directive", directive))
                    except json.JSONDecodeError:
                        pass
                    self._directive_buffer = ""

        return events

    def flush(self) -> list:
        """Call when the stream ends to process any remaining content."""
        events = []
        if not self._in_directive and self._buffer:
            events.append(("text", self._buffer))
            self._buffer = ""
        return events


# Usage example
async def stream_with_directives(ws, task_id, llm_stream, method_map):
    parser = DirectiveStreamParser()

    async for chunk in llm_stream:
        for event_type, data in parser.feed(chunk):
            if event_type == "text":
                await ws.send_json({
                    "jsonrpc": "2.0", "method": "ui.textContent",
                    "params": {"task_id": task_id, "content": data, "is_final": False}
                })
            elif event_type == "directive":
                directive_type = data.pop("type", None)
                method = method_map.get(directive_type)
                if method:
                    data["task_id"] = task_id
                    for id_field in ["confirmation_id", "select_id", "upload_id", "form_id"]:
                        if id_field not in data:
                            data[id_field] = str(uuid.uuid4())[:8]
                    await ws.send_json({
                        "jsonrpc": "2.0", "method": method, "params": data
                    })

    for event_type, data in parser.flush():
        if event_type == "text" and data:
            await ws.send_json({
                "jsonrpc": "2.0", "method": "ui.textContent",
                "params": {"task_id": task_id, "content": data, "is_final": False}
            })
```

### 7.5 Handling User Interaction Responses

After the user interacts with a UI component, the App sends `agent.submitResponse`:

```json
{
  "jsonrpc": "2.0", "method": "agent.submitResponse", "id": 5,
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

`response_data` formats by component type:

| Component | response_data format |
|-----------|---------------------|
| `action_confirmation` | `{ "confirmation_id": "...", "selected_action_id": "action_id" }` |
| `single_select` | `{ "select_id": "...", "selected_option_id": "opt_id" }` |
| `multi_select` | `{ "select_id": "...", "selected_option_ids": ["opt1", "opt2"] }` |
| `file_upload` | `{ "upload_id": "...", "uploaded_file_ids": [...] }` |
| `form` | `{ "form_id": "...", "field_values": { "field_id": "value", ... } }` |

Reply:
```json
{ "jsonrpc": "2.0", "id": 5, "result": { "status": "received" } }
```

---

## 8. File Transfer

### 8.1 HTTP File Serving (Recommended)

The simplest approach: expose an HTTP endpoint on your Agent server, then send `ui.fileMessage` with a URL:

```python
import os, uuid, mimetypes, time
from aiohttp import web

_file_registry = {}  # file_id -> {path, filename, mime_type, size}

async def serve_file_to_user(ws, task_id: str, file_path: str):
    """Register a file for HTTP serving and notify the App."""
    file_id = uuid.uuid4().hex[:12]
    filename = os.path.basename(file_path)
    mime_type, _ = mimetypes.guess_type(file_path)
    size = os.path.getsize(file_path)

    _file_registry[file_id] = {
        "path": file_path,
        "filename": filename,
        "mime_type": mime_type or "application/octet-stream",
        "size": size,
        "created_at": time.time()
    }

    await ws.send_json({
        "jsonrpc": "2.0", "method": "ui.fileMessage",
        "params": {
            "task_id": task_id,
            "url": f"http://your-agent-host:8080/files/{file_id}",
            "filename": filename,
            "mime_type": mime_type or "application/octet-stream",
            "size": size,
        }
    })

async def handle_file_download(request):
    """HTTP endpoint to serve registered files."""
    file_id = request.match_info["file_id"]
    entry = _file_registry.get(file_id)
    if not entry or not os.path.exists(entry["path"]):
        return web.Response(status=404)
    return web.FileResponse(entry["path"], headers={
        "Content-Type": entry["mime_type"],
        "Content-Disposition": f'inline; filename="{entry["filename"]}"'
    })

# Register the route:
# app.router.add_get("/files/{file_id}", handle_file_download)
```

### 8.2 WebSocket Binary Transfer

For scenarios where you cannot expose a public HTTP endpoint, use WebSocket binary frames.

**Binary frame format:**

```
┌────────────┬──────────────────┬──────────────────────────────┐
│  4 bytes   │  12 bytes        │  Variable                    │
│  "FILE"    │  file_id         │  Chunk data                  │
│  (magic)   │  (null-padded)   │                              │
└────────────┴──────────────────┴──────────────────────────────┘
```

**Transfer flow:**

```
Agent                              App
  │── ui.fileMessage (file_id, no url) ──────►│
  │◄── agent.requestFileData {file_id} ───────│
  │── Response: {filename, mime_type, size} ──►│
  │── file.transferStart notification ────────►│
  │── binary frame (chunk 1) ─────────────────►│
  │── binary frame (chunk 2) ─────────────────►│
  │── binary frame (chunk N) ─────────────────►│
  │── file.transferComplete notification ──────►│
```

**Python implementation:**

```python
async def handle_request_file_data(ws, msg_id, params):
    import math
    file_id = params["file_id"]
    entry = _file_registry.get(file_id)
    if not entry:
        await ws.send_json({"jsonrpc": "2.0", "id": msg_id,
                            "error": {"code": -32003, "message": "File not found"}})
        return

    chunk_size = 65536  # 64 KB
    total_size = entry["size"]
    chunk_count = math.ceil(total_size / chunk_size) if total_size > 0 else 1

    # Respond with file metadata
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {
            "file_id": file_id, "filename": entry["filename"],
            "mime_type": entry["mime_type"], "size": total_size,
            "chunk_size": chunk_size, "chunk_count": chunk_count
        }
    })

    # Send transferStart notification
    await ws.send_json({
        "jsonrpc": "2.0", "method": "file.transferStart",
        "params": {"file_id": file_id, "filename": entry["filename"],
                   "mime_type": entry["mime_type"], "size": total_size,
                   "chunk_count": chunk_count}
    })

    # Build frame header
    header = b"FILE" + file_id.encode("utf-8")[:12].ljust(12, b"\x00")

    # Stream binary frames
    with open(entry["path"], "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            await ws.send_bytes(header + chunk)

    # Send transferComplete notification
    await ws.send_json({
        "jsonrpc": "2.0", "method": "file.transferComplete",
        "params": {"file_id": file_id, "total_bytes": total_size}
    })
```

---

## 9. Task Lifecycle Management

### 9.1 Task Cancellation

When the user clicks "Stop", the App sends `agent.cancelTask`:

```json
{
  "jsonrpc": "2.0", "method": "agent.cancelTask",
  "params": { "task_id": "task_abc123" }, "id": 4
}
```

Your Agent should:
1. Respond with an acknowledgement immediately
2. Cancel the corresponding LLM call
3. Send `task.error` with code `-32008` (task cancelled)

```python
_active_tasks = {}  # task_id -> asyncio.Task

# When agent.chat arrives:
task = asyncio.create_task(handle_chat(ws, msg_id, params))
_active_tasks[params["task_id"]] = task

# When agent.cancelTask arrives:
async def handle_cancel(ws, msg_id, params):
    task_id = params.get("task_id", "")
    t = _active_tasks.pop(task_id, None)
    if t:
        t.cancel()
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {"task_id": task_id, "status": "cancelled"}
    })

# In handle_chat, catch CancelledError:
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]
    try:
        # ... normal processing ...
    except asyncio.CancelledError:
        await ws.send_json({
            "jsonrpc": "2.0", "method": "task.error",
            "params": {"task_id": task_id, "message": "Task cancelled", "code": -32008}
        })
    finally:
        _active_tasks.pop(task_id, None)
```

### 9.2 Message Rollback

When the user requests "Regenerate", the App sends `agent.rollback` to remove the last conversation turn:

```json
{
  "jsonrpc": "2.0", "method": "agent.rollback",
  "params": { "session_id": "session_xyz", "message_id": "msg_001" }, "id": 6
}
```

Remove the last `assistant` message and the last `user` message from your local history:

```python
async def handle_rollback(ws, msg_id, params):
    session_id = params.get("session_id", "")
    history = conversation_manager.get(session_id)
    if history and history[-1]["role"] == "assistant":
        history.pop()
    if history and history[-1]["role"] == "user":
        history.pop()
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id, "result": {"status": "ok"}
    })
```

### 9.3 Complete Message Sequence Diagrams

```
App                                              Agent
 │                                                 │
 │── auth.authenticate ───────────────────────────►│
 │◄── {status: "authenticated"} ───────────────────│
 │                                                 │
 │── agent.chat {task_id, message} ───────────────►│
 │◄── {task_id, status: "accepted"} ───────────────│  ← must reply immediately
 │◄── task.started ────────────────────────────────│
 │◄── ui.textContent (chunk 1) ────────────────────│
 │◄── ui.textContent (chunk 2) ────────────────────│
 │         ... (more chunks) ...                   │
 │◄── ui.textContent (is_final=true) ──────────────│  ← must send
 │◄── task.completed ──────────────────────────────│
 │                                                 │
 │── ping ────────────────────────────────────────►│
 │◄── {pong: true} ────────────────────────────────│
```

**Error scenario:**

```
 │── agent.chat ───────────────────────────────────►│
 │◄── {status: "accepted"} ────────────────────────│
 │◄── task.started ────────────────────────────────│
 │◄── ui.textContent (partial) ────────────────────│
 │     ... error occurs ...                        │
 │◄── task.error {message: "...", code: -32603} ───│
```

**Cancellation scenario:**

```
 │── agent.chat ───────────────────────────────────►│
 │◄── {status: "accepted"} ────────────────────────│
 │◄── task.started ────────────────────────────────│
 │◄── ui.textContent (partial) ────────────────────│
 │── agent.cancelTask ─────────────────────────────►│
 │◄── {status: "cancelled"} ───────────────────────│
 │◄── task.error {code: -32008} ───────────────────│
```

---

## 10. Conversation History Management

### 10.1 Core Principles

The App manages conversations by `session_id`. Your Agent should:

1. **First contact for a session**: initialize local state from the `history` array
2. **Subsequent messages**: append to local history (do not rely on the `history` field)
3. **Gap detection**: compare `total_message_count` with your local count

```python
class ConversationManager:
    def __init__(self, max_pairs: int = 20):
        self._sessions: dict = {}
        self._max = max_pairs

    def has(self, sid: str) -> bool:
        return sid in self._sessions

    def init(self, sid: str, history: list):
        """Initialize a session from App-provided history."""
        if sid not in self._sessions:
            self._sessions[sid] = [
                {"role": m["role"], "content": m["content"]}
                for m in history
                if m.get("role") in ("user", "assistant") and m.get("content")
            ]

    def add_user(self, sid: str, content: str):
        self._sessions.setdefault(sid, []).append({"role": "user", "content": content})
        self._trim(sid)

    def add_assistant(self, sid: str, content: str):
        self._sessions.setdefault(sid, []).append({"role": "assistant", "content": content})
        self._trim(sid)

    def get(self, sid: str) -> list:
        return list(self._sessions.get(sid, []))

    def prepend(self, sid: str, older: list):
        """Prepend older history messages (history supplement scenario)."""
        if sid in self._sessions:
            valid = [m for m in older if m.get("role") in ("user", "assistant") and m.get("content")]
            self._sessions[sid] = valid + self._sessions[sid]

    def rollback(self, sid: str):
        msgs = self._sessions.get(sid, [])
        for role in ("assistant", "user"):
            if msgs and msgs[-1]["role"] == role:
                msgs.pop()

    def _trim(self, sid: str):
        msgs = self._sessions[sid]
        if len(msgs) > self._max * 2:
            self._sessions[sid] = msgs[-(self._max * 2):]
```

### 10.2 Handling History Supplements

After you send `ui.requestHistory`, the App delivers a supplemental request:

```json
{
  "method": "agent.chat",
  "params": {
    "history_supplement": true,
    "additional_history": [ ... older messages ... ],
    "original_question": "the user's original question text"
  }
}
```

Handling:

```python
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]
    session_id = params.get("session_id", task_id)

    if params.get("history_supplement"):
        additional = params.get("additional_history", [])
        if additional:
            conv_mgr.prepend(session_id, additional)
        # Remove any incomplete assistant reply
        msgs = conv_mgr.get(session_id)
        if msgs and msgs[-1]["role"] == "assistant":
            msgs.pop()
        # Re-generate using the enriched history (no new user message)
        messages = conv_mgr.get(session_id)
    else:
        if not conv_mgr.has(session_id) and params.get("history"):
            conv_mgr.init(session_id, params["history"])
        conv_mgr.add_user(session_id, params.get("message", ""))
        messages = conv_mgr.get(session_id)

    # ... proceed to call LLM with `messages` ...
```

---

## 11. Hub Data Queries (Agent → App)

Your Agent can proactively request data from the App. These are **requests** (they have an `id`) and require a response.

### 11.1 General Hub Request Pattern

```python
async def hub_request(ws, pending: dict, method: str, params=None, timeout=10.0):
    """Send a request to the App and wait for its response."""
    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    pending[req_id] = future

    msg = {"jsonrpc": "2.0", "method": method, "id": req_id}
    if params:
        msg["params"] = params
    await ws.send_json(msg)

    try:
        return await asyncio.wait_for(future, timeout=timeout)
    except asyncio.TimeoutError:
        pending.pop(req_id, None)
        raise

# In your message loop, handle responses (has id, no method):
elif mid is not None and method is None:
    future = pending.pop(mid, None)
    if future and not future.done():
        if data.get("error"):
            future.set_exception(RuntimeError(data["error"]["message"]))
        else:
            future.set_result(data.get("result"))
```

### 11.2 Get Session List

```json
// Agent sends
{ "jsonrpc": "2.0", "method": "hub.getSessions", "id": "req_001" }

// App responds
{
  "jsonrpc": "2.0", "id": "req_001",
  "result": {
    "sessions": [
      {
        "id": "session_abc",
        "title": "Session title",
        "agent_id": "agent_xyz",
        "created_at": 1700000000000,
        "updated_at": 1700000001000
      }
    ]
  }
}
```

### 11.3 Get Session Messages

```json
// Agent sends
{
  "jsonrpc": "2.0",
  "method": "hub.getSessionMessages",
  "params": { "session_id": "session_abc", "limit": 50 },
  "id": "req_002"
}
```

### 11.4 Get Agent List

```json
{ "jsonrpc": "2.0", "method": "hub.getAgentList", "id": "req_003" }
```

### 11.5 Get Hub Info

```json
{ "jsonrpc": "2.0", "method": "hub.getHubInfo", "id": "req_004" }
```

### 11.6 Get Attachment Content

Fetch the full data of an attachment from a message:

```json
{
  "jsonrpc": "2.0",
  "method": "hub.getAttachmentContent",
  "params": { "attachment_id": "att_abc123" },
  "id": "req_005"
}
```

### 11.7 Initiate a New Chat

Your Agent can proactively start a new conversation with the user (requires App user authorization):

```json
{
  "jsonrpc": "2.0",
  "method": "hub.initiateChat",
  "params": {
    "message": "Hello, I have some important information for you.",
    "agent_id": "my-agent-id"
  },
  "id": "req_006"
}
```

---

## 12. Group Chat Support

When multiple Agents participate in the same session, `agent.chat` includes a `group_context` field:

```json
{
  "group_context": {
    "group_id": "group_abc",
    "group_name": "My Work Group",
    "members": [
      { "id": "agent_1", "name": "Agent A", "type": "agent" },
      { "id": "agent_2", "name": "Agent B", "type": "agent" },
      { "id": "user_001", "name": "User", "type": "user" }
    ],
    "current_agent_id": "agent_1"
  }
}
```

In group scenarios:
- Use `current_agent_id` to confirm it is your turn to reply
- The `system_prompt` field will contain group context information
- Each agent's reply appears in turn within the same session

---

## 13. Complete Implementation Example

A production-ready Python Agent skeleton with all core features:

```python
#!/usr/bin/env python3
"""
Shepaw ACP Remote Agent — production skeleton
Supports: streaming, task cancellation, session history, UI components, file serving
"""

import asyncio
import json
import uuid
import os
import time
import mimetypes
import math
from datetime import datetime
from typing import Optional
import aiohttp
from aiohttp import web


# ─── JSON-RPC helpers ─────────────────────────────────────────────────────────

def rpc_ok(id, result=None):
    return {"jsonrpc": "2.0", "id": id, "result": result or {}}

def rpc_err(id, code: int, message: str):
    return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

def notify(method: str, params: dict):
    return {"jsonrpc": "2.0", "method": method, "params": params}


# ─── Conversation history ─────────────────────────────────────────────────────

class ConversationManager:
    def __init__(self, max_pairs: int = 20):
        self._sessions: dict = {}
        self._max = max_pairs

    def has(self, sid: str) -> bool:
        return sid in self._sessions

    def init(self, sid: str, history: list):
        if sid not in self._sessions:
            self._sessions[sid] = [
                {"role": m["role"], "content": m["content"]}
                for m in history
                if m.get("role") in ("user", "assistant") and m.get("content")
            ]

    def add_user(self, sid: str, content: str):
        self._sessions.setdefault(sid, []).append({"role": "user", "content": content})
        self._trim(sid)

    def add_assistant(self, sid: str, content: str):
        self._sessions.setdefault(sid, []).append({"role": "assistant", "content": content})
        self._trim(sid)

    def get(self, sid: str) -> list:
        return list(self._sessions.get(sid, []))

    def prepend(self, sid: str, older: list):
        if sid in self._sessions:
            valid = [m for m in older if m.get("role") in ("user", "assistant") and m.get("content")]
            self._sessions[sid] = valid + self._sessions[sid]

    def rollback(self, sid: str):
        msgs = self._sessions.get(sid, [])
        for role in ("assistant", "user"):
            if msgs and msgs[-1]["role"] == role:
                msgs.pop()

    def _trim(self, sid: str):
        msgs = self._sessions[sid]
        if len(msgs) > self._max * 2:
            self._sessions[sid] = msgs[-(self._max * 2):]


# ─── File registry ────────────────────────────────────────────────────────────

class FileRegistry:
    def __init__(self):
        self._files: dict = {}

    def register(self, path: str) -> str:
        file_id = uuid.uuid4().hex[:12]
        self._files[file_id] = {
            "path": path,
            "filename": os.path.basename(path),
            "mime_type": mimetypes.guess_type(path)[0] or "application/octet-stream",
            "size": os.path.getsize(path),
            "created_at": time.time(),
        }
        return file_id

    def get(self, file_id: str) -> Optional[dict]:
        return self._files.get(file_id)


# ─── Agent ────────────────────────────────────────────────────────────────────

class MyAgent:
    def __init__(
        self,
        token: str = "",
        name: str = "My Remote Agent",
        description: str = "A Shepaw-compatible remote agent",
        version: str = "1.0.0",
        port: int = 8080,
    ):
        self.token = token
        self.name = name
        self.description = description
        self.version = version
        self.port = port

        self._conv = ConversationManager()
        self._files = FileRegistry()
        self._active_tasks: dict = {}
        self._pending: dict = {}

    async def _handle_all(self, request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        state = {"authed": False}
        print("[connect] new client")

        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    method = data.get("method")
                    mid = data.get("id")
                    params = data.get("params") or {}

                    if mid is not None and method is not None:
                        # Request from App
                        await self._dispatch(ws, method, mid, params, state)
                    elif mid is not None and method is None:
                        # Response to our hub.* request
                        fut = self._pending.pop(mid, None)
                        if fut and not fut.done():
                            if data.get("error"):
                                fut.set_exception(RuntimeError(str(data["error"])))
                            else:
                                fut.set_result(data.get("result"))
                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                    break
        except Exception as e:
            print(f"[error] {e}")
        finally:
            for t in self._active_tasks.values():
                t.cancel()
            self._active_tasks.clear()

        return ws

    async def _dispatch(self, ws, method: str, mid, params: dict, state: dict):
        authed = state["authed"]

        if method == "auth.authenticate":
            if not self.token or params.get("token") == self.token:
                state["authed"] = True
                await ws.send_json(rpc_ok(mid, {"status": "authenticated"}))
            else:
                await ws.send_json(rpc_err(mid, -32000, "Authentication failed"))
            return

        if method == "ping":
            await ws.send_json(rpc_ok(mid, {"pong": True}))
            return

        if not authed:
            await ws.send_json(rpc_err(mid, -32001, "Not authenticated"))
            return

        if method == "agent.getCard":
            await ws.send_json(rpc_ok(mid, {
                "agent_id": "my-remote-agent",
                "name": self.name,
                "description": self.description,
                "version": self.version,
                "capabilities": ["chat", "streaming", "interactive_messages", "file_transfer"],
                "supported_protocols": ["acp"],
            }))

        elif method == "agent.chat":
            task_id = params.get("task_id", str(uuid.uuid4()))
            task = asyncio.create_task(self._handle_chat(ws, mid, params))
            self._active_tasks[task_id] = task

        elif method == "agent.cancelTask":
            task_id = params.get("task_id", "")
            t = self._active_tasks.pop(task_id, None)
            if t:
                t.cancel()
            await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "cancelled"}))

        elif method == "agent.submitResponse":
            await ws.send_json(rpc_ok(mid, {"status": "received"}))
            rd = params.get("response_data", {})
            for key in ("confirmation_id", "select_id", "upload_id", "form_id"):
                cid = rd.get(key)
                if cid:
                    fut = self._pending.pop(cid, None)
                    if fut and not fut.done():
                        fut.set_result(rd)

        elif method == "agent.rollback":
            self._conv.rollback(params.get("session_id", ""))
            await ws.send_json(rpc_ok(mid, {"status": "ok"}))

        elif method == "agent.requestFileData":
            await self._handle_request_file_data(ws, mid, params)

        else:
            await ws.send_json(rpc_err(mid, -32601, f"Method not found: {method}"))

    async def _handle_chat(self, ws, mid, params: dict):
        task_id = params.get("task_id", str(uuid.uuid4()))
        session_id = params.get("session_id", task_id)
        message = params.get("message", "")
        attachments = params.get("attachments") or []

        await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "accepted"}))
        await ws.send_json(notify("task.started", {
            "task_id": task_id, "started_at": datetime.now().isoformat()
        }))

        try:
            if params.get("history_supplement"):
                additional = params.get("additional_history", [])
                if additional:
                    self._conv.prepend(session_id, additional)
                msgs = self._conv.get(session_id)
                if msgs and msgs[-1]["role"] == "assistant":
                    msgs.pop()
            else:
                if not self._conv.has(session_id) and params.get("history"):
                    self._conv.init(session_id, params["history"])
                if message:
                    self._conv.add_user(session_id, message)

            messages = self._conv.get(session_id)

            # ─────────────────────────────────────────────────────────
            # Replace this with your LLM call.
            # For streaming, iterate over chunks from your LLM stream.
            # ─────────────────────────────────────────────────────────
            reply_text = await self._call_llm(message, messages, attachments)

            chunk_size = 10
            for i in range(0, len(reply_text), chunk_size):
                await ws.send_json(notify("ui.textContent", {
                    "task_id": task_id,
                    "content": reply_text[i:i + chunk_size],
                    "is_final": False
                }))
                await asyncio.sleep(0.02)

            self._conv.add_assistant(session_id, reply_text)

            # Final marker — REQUIRED
            await ws.send_json(notify("ui.textContent", {
                "task_id": task_id, "content": "", "is_final": True
            }))
            await ws.send_json(notify("task.completed", {
                "task_id": task_id, "status": "success",
                "completed_at": datetime.now().isoformat()
            }))

        except asyncio.CancelledError:
            await ws.send_json(notify("task.error", {
                "task_id": task_id, "message": "Task cancelled", "code": -32008
            }))
        except Exception as e:
            await ws.send_json(notify("task.error", {
                "task_id": task_id, "message": str(e), "code": -32603
            }))
        finally:
            self._active_tasks.pop(task_id, None)

    async def _call_llm(self, message: str, history: list, attachments: list) -> str:
        """
        Implement your LLM call here.
        Return the complete reply text (non-streaming).
        For streaming support, convert this to an async generator.
        """
        if attachments:
            names = [a["file_name"] for a in attachments]
            return f"Received your message: {message}\nAttachments: {', '.join(names)}"
        return f"You said: {message}"

    async def _handle_request_file_data(self, ws, mid, params: dict):
        file_id = params.get("file_id", "")
        entry = self._files.get(file_id)
        if not entry:
            await ws.send_json(rpc_err(mid, -32003, f"File not found: {file_id}"))
            return

        chunk_size = 65536
        total = entry["size"]
        count = math.ceil(total / chunk_size) if total > 0 else 1

        await ws.send_json(rpc_ok(mid, {
            "file_id": file_id, "filename": entry["filename"],
            "mime_type": entry["mime_type"], "size": total,
            "chunk_size": chunk_size, "chunk_count": count
        }))
        await ws.send_json(notify("file.transferStart", {
            "file_id": file_id, "filename": entry["filename"],
            "mime_type": entry["mime_type"], "size": total, "chunk_count": count
        }))

        header = b"FILE" + file_id.encode("utf-8")[:12].ljust(12, b"\x00")
        with open(entry["path"], "rb") as f:
            while True:
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                await ws.send_bytes(header + chunk)

        await ws.send_json(notify("file.transferComplete", {
            "file_id": file_id, "total_bytes": total
        }))

    async def _hub_request(self, ws, method: str, params=None, timeout=10.0):
        req_id = str(uuid.uuid4())
        loop = asyncio.get_running_loop()
        future = loop.create_future()
        self._pending[req_id] = future
        msg = {"jsonrpc": "2.0", "method": method, "id": req_id}
        if params:
            msg["params"] = params
        await ws.send_json(msg)
        return await asyncio.wait_for(future, timeout=timeout)

    async def handle_file_serve(self, request: web.Request) -> web.Response:
        file_id = request.match_info.get("file_id", "")
        entry = self._files.get(file_id)
        if not entry or not os.path.exists(entry["path"]):
            return web.Response(status=404, text="File not found")
        return web.FileResponse(entry["path"], headers={
            "Content-Type": entry["mime_type"],
            "Content-Disposition": f'inline; filename="{entry["filename"]}"'
        })

    def run(self, host: str = "0.0.0.0"):
        app = web.Application()
        app.router.add_get("/acp/ws", self._handle_all)
        app.router.add_get("/files/{file_id}", self.handle_file_serve)
        print(f"[start] {self.name} listening on {host}:{self.port}")
        print(f"[start] WebSocket endpoint: ws://{host}:{self.port}/acp/ws")
        web.run_app(app, host=host, port=self.port)


# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    agent = MyAgent(
        token=os.getenv("AGENT_TOKEN", "my-secret-token"),
        name="My Remote LLM Agent",
        description="A remote LLM agent built on the Shepaw ACP protocol",
        version="1.0.0",
        port=int(os.getenv("PORT", "8080")),
    )
    agent.run()
```

**Run:**

```bash
pip install aiohttp
AGENT_TOKEN=my-secret-token python my_agent.py
```

---

## 14. Error Code Reference

### JSON-RPC Standard Errors

| Code | Name | Description |
|------|------|-------------|
| `-32700` | Parse error | Invalid JSON received |
| `-32600` | Invalid request | JSON is not a valid JSON-RPC request |
| `-32601` | Method not found | The requested method does not exist |
| `-32602` | Invalid params | Invalid method parameters |
| `-32603` | Internal error | Generic server-side error |

### Application-Level Errors

| Code | Name | Description |
|------|------|-------------|
| `-32000` | Authentication failed | Token is invalid or missing |
| `-32001` | Unauthorized | Authenticated but not authorized for this action |
| `-32002` | Permission denied | Specific permission not granted |
| `-32003` | Not found | Task, file, or session does not exist |
| `-32004` | Pending approval | Action requires user approval |
| `-32005` | Session not found | Conversation session does not exist |
| `-32006` | Task failed | Task execution failed |
| `-32007` | Timeout | Operation timed out |
| `-32008` | Task cancelled | Task was cancelled by the user |

---

## 15. Registering Your Agent in Shepaw

1. Open the Shepaw App
2. Navigate to **Settings → Agents → Add Agent**
3. Fill in the following fields:
   - **Agent Name**: display name (customizable)
   - **WebSocket Address**: `ws://your-host:8080/acp/ws`
   - **Token**: the authentication token your Agent server uses
   - **Protocol**: select `ACP`
4. Save — the App will immediately attempt to connect and authenticate
5. Once connected, the Agent status shows as "Online"

**Local development tips:**
- iOS/Android devices on the same LAN: use your machine's local IP (e.g. `ws://192.168.1.100:8080/acp/ws`)
- macOS/Windows desktop: use `ws://localhost:8080/acp/ws`
- For public internet access, use a tunneling tool such as `ngrok` or `frp`

---

## 16. FAQ

### Q: What is the minimum I need to implement?

Handle just these 3 methods and you have a working agent:
1. `auth.authenticate` — validate the token and return success
2. `ping` — return pong
3. `agent.chat` — acknowledge, send `task.started`, stream `ui.textContent`, send `is_final=true`, send `task.completed`

### Q: Is the `is_final=true` ui.textContent mandatory?

**Yes, absolutely.** The App relies on this signal to finalize the message bubble. Without it, the message stays in a "loading" state until it times out.

### Q: How do I handle multiple concurrent conversations?

Each `agent.chat` request has a unique `task_id`. Use `asyncio.create_task()` to spawn an independent coroutine for each request, stored by `task_id` in a dictionary. This allows simultaneous processing and individual task cancellation.

### Q: What happens when the WebSocket disconnects?

The App reconnects automatically (up to 5 attempts, exponential backoff). Your Agent should:
- Cancel all in-progress tasks on disconnect
- Clean up pending hub request futures
- Accept fresh connections without assuming any prior state

### Q: How do I transfer files without running an HTTP server?

Use WebSocket binary frame transfer (see Section 8.2). When sending `ui.fileMessage`, omit the `url` field and include only `file_id`. The App will then send `agent.requestFileData`, and you stream the file as binary frames.

### Q: How do I test my Agent without the App?

Use `wscat` (a command-line WebSocket client):

```bash
npm install -g wscat
wscat -c ws://localhost:8080/acp/ws

# Authenticate
> {"jsonrpc":"2.0","method":"auth.authenticate","params":{"token":"my-secret-token"},"id":1}

# Heartbeat
> {"jsonrpc":"2.0","method":"ping","params":{},"id":2}

# Send a message
> {"jsonrpc":"2.0","method":"agent.chat","params":{"task_id":"t1","session_id":"s1","message":"Hello","user_id":"u1","message_id":"m1"},"id":3}
```

### Q: When does the `history` field contain data?

- **New session** (Agent has not seen this `session_id` before): full history included
- **Gap detected** by the App: history may be resent for re-sync
- **Subsequent messages** within the same WebSocket session: typically empty — your Agent maintains its own local history

### Q: What is `ui_component_version` for?

It marks the version of the App's UI component registry. If it changes between requests, the App has been updated and you should re-call `hub.getUIComponentTemplates` to refresh your cached component definitions and directive prompt.

---

## Appendix: Protocol Method Quick Reference

### App → Agent Requests

| Method | Description |
|--------|-------------|
| `auth.authenticate` | Authentication handshake |
| `agent.chat` | Send a message (core method) |
| `agent.cancelTask` | Cancel a running task |
| `agent.submitResponse` | Submit UI component interaction result |
| `agent.rollback` | Roll back the last conversation turn |
| `agent.getCard` | Get Agent metadata card |
| `agent.requestFileData` | Request WebSocket file transfer |
| `ping` | Heartbeat check |

### Agent → App Notifications

| Method | Description |
|--------|-------------|
| `ui.textContent` | Streaming text (`is_final=true` marks end) |
| `ui.actionConfirmation` | Action button component |
| `ui.singleSelect` | Single-choice list component |
| `ui.multiSelect` | Multi-choice list component |
| `ui.fileUpload` | Request user file upload |
| `ui.form` | Structured form component |
| `ui.fileMessage` | Deliver a file to the user |
| `ui.messageMetadata` | Collapsible content metadata |
| `ui.requestHistory` | Request additional session history |
| `task.started` | Task has started |
| `task.completed` | Task has completed |
| `task.error` | Task failed or was cancelled |
| `file.transferStart` | File transfer beginning |
| `file.transferComplete` | File transfer finished |
| `file.transferError` | File transfer failed |

### Agent → App Requests (Hub)

| Method | Description |
|--------|-------------|
| `hub.getUIComponentTemplates` | Get UI component definitions and directive prompt |
| `hub.getSessions` | Get session list |
| `hub.getSessionMessages` | Get messages for a session |
| `hub.getAgentList` | Get list of registered Agents |
| `hub.getHubInfo` | Get Hub metadata |
| `hub.getAttachmentContent` | Get full attachment content |
| `hub.initiateChat` | Proactively start a new chat |

# Shepaw Remote LLM Agent 接入指南

> 适用于希望将自己的 LLM / AI Agent 接入 Shepaw 的第三方开发者
>
> 协议版本：ACP 1.0 | 文档更新：2026-03-22

> **Language / 语言:** **中文** | [English](remote_llm_agent_integration_en.md)

---

## 目录

1. [概述](#1-概述)
2. [快速上手](#2-快速上手)
3. [协议规范](#3-协议规范)
4. [连接与认证](#4-连接与认证)
5. [核心消息流：agent.chat](#5-核心消息流agentchat)
6. [附件与多模态支持](#6-附件与多模态支持)
7. [UI 交互组件](#7-ui-交互组件)
8. [文件传输](#8-文件传输)
9. [任务生命周期管理](#9-任务生命周期管理)
10. [会话历史管理](#10-会话历史管理)
11. [Hub 数据查询（Agent → App）](#11-hub-数据查询agent--app)
12. [群组聊天支持](#12-群组聊天支持)
13. [完整实现示例](#13-完整实现示例)
14. [错误码参考](#14-错误码参考)
15. [在 Shepaw 中注册你的 Agent](#15-在-shepaw-中注册你的-agent)
16. [常见问题](#16-常见问题)

---

## 1. 概述

### 1.1 架构

Shepaw 使用 **ACP（Agent Communication Protocol）** 协议与 Remote Agent 通信。ACP 基于 **JSON-RPC 2.0 over WebSocket**，支持双向消息传递。

```
┌──────────────────────┐         WebSocket (JSON-RPC 2.0)         ┌──────────────────────┐
│                      │ ──────────────────────────────────────► │                      │
│   Shepaw（App 端）   │    App→Agent: agent.chat, agent.cancel   │   你的 Remote Agent  │
│   (Flutter 客户端)   │   Agent→App: ui.textContent, task.*      │   (Python / 任意语言)│
│                      │ ◄──────────────────────────────────────  │                      │
└──────────────────────┘   Agent→App: hub.* 请求                  └──────────────────────┘
```

### 1.2 你的 Agent 需要做什么

**必须实现（最小集）：**

1. 启动 WebSocket 服务器，监听 `/acp/ws` 端点
2. 处理 `auth.authenticate` 认证请求
3. 处理 `agent.chat` 消息并通过 `ui.textContent` 流式返回响应
4. 发送 `task.started` / `task.completed` / `task.error` 任务生命周期事件
5. 响应 `ping` 心跳

**可选功能：**

- 发送富交互 UI 组件（按钮、表单、选择器等）
- 接收并处理用户上传的附件（图片、文件、音频）
- 通过 `hub.*` 接口查询 App 中的会话数据
- 通过 HTTP 或 WebSocket 二进制帧发送文件给用户
- 支持群组聊天场景

### 1.3 通信模式总览

| 方向 | 类型 | 方法 |
|------|------|------|
| App → Agent | 请求 | `auth.authenticate`, `agent.chat`, `agent.cancelTask`, `agent.submitResponse`, `agent.rollback`, `agent.getCard`, `ping` |
| Agent → App | 通知 | `ui.textContent`, `ui.actionConfirmation`, `ui.singleSelect`, `ui.multiSelect`, `ui.fileUpload`, `ui.form`, `ui.fileMessage`, `ui.messageMetadata`, `ui.requestHistory` |
| Agent → App | 任务事件 | `task.started`, `task.completed`, `task.error` |
| Agent → App | 请求 | `hub.getUIComponentTemplates`, `hub.getSessions`, `hub.getSessionMessages`, `hub.getAgentList`, `hub.getHubInfo`, `hub.getAttachmentContent`, `hub.initiateChat` |
| Bidirectional | 心跳 | `ping` / `pong` |

---

## 2. 快速上手

以下是一个**最简可运行**的 Python Agent，约 70 行代码：

```python
#!/usr/bin/env python3
"""Shepaw ACP 最简 Agent 示例"""

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

            # 1. 立即确认收到
            await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "accepted"}))
            # 2. 任务开始
            await ws.send_json(notify("task.started", {
                "task_id": task_id, "started_at": datetime.now().isoformat()
            }))
            # 3. 流式发送回复（这里替换成你自己的 LLM 调用）
            reply = f"你说：{message}"
            for chunk in [reply[i:i+5] for i in range(0, len(reply), 5)]:
                await ws.send_json(notify("ui.textContent", {
                    "task_id": task_id, "content": chunk, "is_final": False
                }))
                await asyncio.sleep(0.05)
            # 4. 标记文本流结束（必须）
            await ws.send_json(notify("ui.textContent", {
                "task_id": task_id, "content": "", "is_final": True
            }))
            # 5. 任务完成
            await ws.send_json(notify("task.completed", {
                "task_id": task_id, "status": "success",
                "completed_at": datetime.now().isoformat()
            }))

        elif method == "agent.getCard":
            await ws.send_json(rpc_ok(mid, {
                "agent_id": "my-llm-agent",
                "name": "My LLM Agent",
                "description": "一个简单的 LLM Agent 示例",
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

**启动并注册：**

```bash
pip install aiohttp
python my_agent.py
# 在 Shepaw App 中添加 Remote Agent：
#   地址: ws://<你的IP>:8080/acp/ws
#   Token: my-secret-token
```

---

## 3. 协议规范

### 3.1 传输层

| 属性 | 值 |
|------|-----|
| 协议 | WebSocket (RFC 6455) |
| 端点 | `ws://<host>:<port>/acp/ws`（路径可自定义） |
| 编码 | UTF-8 JSON 文本帧 |
| 二进制帧 | 仅用于文件传输（见第 8 节） |
| 默认端口 | 自定义（无强制要求） |

### 3.2 JSON-RPC 2.0 消息类型

ACP 使用标准 JSON-RPC 2.0 格式。通过 `id` 和 `method` 字段区分消息类型：

**请求**（有 `id` 且有 `method`）：
```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "params": { "task_id": "...", "message": "你好" },
  "id": 1
}
```

**响应**（有 `id`，无 `method`）：
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "task_id": "...", "status": "accepted" }
}
```

**错误响应**：
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32000, "message": "Authentication failed" }
}
```

**通知**（有 `method`，无 `id`）：
```json
{
  "jsonrpc": "2.0",
  "method": "ui.textContent",
  "params": { "task_id": "...", "content": "你好", "is_final": false }
}
```

> **关键规则**：同一个 WebSocket 连接上同时承载双向的请求/响应模式与通知模式。解析消息时，先判断 `id` 和 `method` 字段是否存在来区分消息类型。

---

## 4. 连接与认证

### 4.1 连接建立

App 启动时会主动连接到你 Agent 的 WebSocket 端点。连接成功后，App 会立即发送认证请求。

你的服务器无需在 HTTP 升级阶段做任何特殊处理，只需接受标准 WebSocket 连接即可。

### 4.2 认证握手

连接建立后的第一条消息是 `auth.authenticate`：

```json
// App 发送
{
  "jsonrpc": "2.0",
  "method": "auth.authenticate",
  "params": { "token": "your-agent-token" },
  "id": 1
}

// 认证成功
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": { "status": "authenticated" }
}

// 认证失败
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": { "code": -32000, "message": "Authentication failed" }
}
```

**注意**：认证失败后你可以继续保持连接并等待重试，也可以直接关闭连接。在认证成功之前，拒绝所有其他请求（`ping` 除外）。

### 4.3 心跳保活

App 每 **30 秒**发送一次 `ping`，你必须回复 `pong`：

```json
// App 发送
{ "jsonrpc": "2.0", "method": "ping", "params": {}, "id": 2 }

// Agent 回复
{ "jsonrpc": "2.0", "id": 2, "result": { "pong": true } }
```

> **注意**：连续 3 次未响应 `ping`，App 会断开连接并尝试重连（最多 5 次，指数退避）。

---

## 5. 核心消息流：agent.chat

### 5.1 请求格式

```json
{
  "jsonrpc": "2.0",
  "method": "agent.chat",
  "id": 3,
  "params": {
    "task_id": "task_abc123",
    "session_id": "session_xyz",
    "message": "帮我分析一下这份数据",
    "user_id": "user_001",
    "message_id": "msg_001",
    "history": [
      { "role": "user", "content": "你好" },
      { "role": "assistant", "content": "你好！有什么可以帮助你的？" }
    ],
    "total_message_count": 10,
    "ui_component_version": "1.0.0",
    "system_prompt": null,
    "group_context": null,
    "attachments": null
  }
}
```

**参数说明：**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `task_id` | string | 是 | 本次请求的唯一任务 ID，用于追踪整个响应流 |
| `session_id` | string | 是 | 会话/对话 ID，用于管理上下文历史 |
| `message` | string | 是* | 用户消息文本（附件消息时可为空字符串） |
| `user_id` | string | 是 | 发送消息的用户 ID |
| `message_id` | string | 是 | 本条消息的唯一 ID |
| `history` | array | 否 | 对话历史（新会话或历史同步时携带） |
| `total_message_count` | int | 否 | App 中该会话的总消息数，用于检测历史缺口 |
| `ui_component_version` | string | 否 | App UI 组件注册表版本，变化时需重新拉取组件模板 |
| `history_supplement` | bool | 否 | `true` 表示这是历史补充请求（见第 10 节） |
| `additional_history` | array | 否 | 补充的更早历史消息 |
| `original_question` | string | 否 | 历史补充场景下的原始问题 |
| `system_prompt` | string | 否 | 系统提示词覆盖（群组聊天等场景使用） |
| `group_context` | object | 否 | 群组聊天元数据（见第 12 节） |
| `attachments` | array | 否 | 用户附件列表（见第 6 节） |

### 5.2 标准响应流程

收到 `agent.chat` 后，必须严格按以下顺序响应：

```
┌─────────────────────────────────────────────────────────┐
│  Step 1: 立即发送 JSON-RPC 响应（确认收到）             │
│  Step 2: 发送 task.started 通知                         │
│  Step 3: 发送多个 ui.textContent 通知（流式文本）        │
│  Step 4: 发送 ui.textContent（is_final=true）           │
│  Step 5: 发送 task.completed 通知                       │
└─────────────────────────────────────────────────────────┘
```

```python
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]
    
    # Step 1: 确认收到（必须立即发送，不能等 LLM 响应）
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {"task_id": task_id, "status": "accepted"}
    })
    
    # Step 2: 任务开始
    await ws.send_json({
        "jsonrpc": "2.0", "method": "task.started",
        "params": {"task_id": task_id, "started_at": datetime.now().isoformat()}
    })
    
    # Step 3: 流式发送文本（调用你的 LLM）
    async for chunk in call_your_llm(params["message"]):
        await ws.send_json({
            "jsonrpc": "2.0", "method": "ui.textContent",
            "params": {"task_id": task_id, "content": chunk, "is_final": False}
        })
    
    # Step 4: 标记文本流结束（必须，App 靠此关闭消息气泡）
    await ws.send_json({
        "jsonrpc": "2.0", "method": "ui.textContent",
        "params": {"task_id": task_id, "content": "", "is_final": True}
    })
    
    # Step 5: 任务完成
    await ws.send_json({
        "jsonrpc": "2.0", "method": "task.completed",
        "params": {"task_id": task_id, "status": "success",
                   "completed_at": datetime.now().isoformat()}
    })
```

> **重要**：`is_final=true` 的 `ui.textContent` 是强制要求的。App 依赖此信号来结束消息气泡渲染。遗漏此步骤会导致消息一直显示"加载中"状态。

### 5.3 history 字段格式

`history` 数组中的每条消息格式：

```json
[
  { "role": "user", "content": "你好" },
  { "role": "assistant", "content": "你好！有什么可以帮助你的？" },
  { "role": "user", "content": "帮我写一首诗" },
  { "role": "assistant", "content": "好的，为你献上..." }
]
```

- `role`：`"user"` 或 `"assistant"`
- `content`：消息文本内容（字符串）

---

## 6. 附件与多模态支持

### 6.1 附件数据格式

当用户发送图片、文件或音频时，`agent.chat` 的 `attachments` 字段会包含附件列表：

```json
{
  "attachments": [
    {
      "file_name": "photo.jpg",
      "mime_type": "image/jpeg",
      "size": 204800,
      "data": "base64编码的文件内容...",
      "type": "image",
      "extra": null
    },
    {
      "file_name": "document.pdf",
      "mime_type": "application/pdf",
      "size": 1048576,
      "data": "base64编码的文件内容...",
      "type": "document",
      "extra": null
    },
    {
      "file_name": "voice_message.m4a",
      "mime_type": "audio/m4a",
      "size": 51200,
      "data": "base64编码的文件内容...",
      "type": "audio",
      "extra": {
        "duration_ms": 5000
      }
    }
  ]
}
```

**附件字段说明：**

| 字段 | 类型 | 说明 |
|------|------|------|
| `file_name` | string | 原始文件名 |
| `mime_type` | string | 文件 MIME 类型 |
| `size` | int | 文件大小（字节） |
| `data` | string | Base64 编码的文件内容 |
| `type` | string | 语义类型：`image`、`audio`、`video`、`document`、`file` |
| `extra` | object/null | 额外元数据，如音频的 `duration_ms`（毫秒时长） |

**大小限制**：单个附件最大 **20MB**。

### 6.2 处理附件示例

```python
import base64

async def handle_chat_with_attachments(ws, msg_id, params):
    task_id = params["task_id"]
    message = params.get("message", "")
    attachments = params.get("attachments") or []

    # 解析附件
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

    # 构造发给 LLM 的 messages（以 OpenAI 多模态格式为例）
    user_content = []
    if message:
        user_content.append({"type": "text", "text": message})
    
    for img in images:
        b64 = base64.b64encode(img["bytes"]).decode()
        user_content.append({
            "type": "image_url",
            "image_url": {
                "url": f"data:{img['mime_type']};base64,{b64}"
            }
        })
    
    # 调用多模态 LLM...
```

---

## 7. UI 交互组件

你的 Agent 可以在聊天中嵌入富交互组件。有两种使用方式：

### 7.1 两种发送模式

| 模式 | 适用场景 | 原理 |
|------|---------|------|
| **指令语法（Directive）** | 不支持 Function Calling 的 LLM | LLM 在文本中输出 `<<<directive ... >>>` 块；你解析后转为 `ui.*` 通知 |
| **Tool Calling** | 支持 Function Calling 的 LLM | LLM 直接调用 UI 组件函数；你将 tool_call 结果转为 `ui.*` 通知 |

两种模式最终都通过相同的 `ui.*` JSON-RPC 通知发送给 App。

### 7.2 动态获取组件定义

在发送 UI 组件之前，通过 `hub.getUIComponentTemplates` 获取最新的组件模板：

```python
async def fetch_ui_templates(ws, pending_requests):
    """从 App 获取 UI 组件模板（建议启动时调用一次并缓存）"""
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
        # 指令语法模式：注入到 system prompt
        "directive_prompt": result["prompt_templates"]["acp_directive_prompt"],
        # Tool Calling 模式：合并到工具列表
        "openai_tools": result["schemas"]["openai_tools"],
        "claude_tools": result["schemas"]["claude_tools"],
        # 方法映射：组件类型名 -> ACP 通知方法
        "method_map": {
            c["name"]: c["acp_notification_method"]
            for c in result["components"]
        }
    }
```

### 7.3 通知消息格式

#### `ui.textContent` — 流式文本

```json
// 流式片段
{
  "jsonrpc": "2.0", "method": "ui.textContent",
  "params": { "task_id": "task_abc123", "content": "正在分析...", "is_final": false }
}

// 结束标记（必须发送）
{
  "jsonrpc": "2.0", "method": "ui.textContent",
  "params": { "task_id": "task_abc123", "content": "", "is_final": true }
}
```

#### `ui.actionConfirmation` — 操作按钮

```json
{
  "jsonrpc": "2.0", "method": "ui.actionConfirmation",
  "params": {
    "task_id": "task_abc123",
    "confirmation_id": "confirm_1a2b3c",
    "prompt": "是否执行此操作？",
    "actions": [
      { "id": "approve", "label": "确认执行", "style": "primary" },
      { "id": "modify", "label": "修改参数", "style": "secondary" },
      { "id": "cancel", "label": "取消", "style": "danger" }
    ]
  }
}
```

按钮样式：`"primary"`（主要操作）、`"secondary"`（次要操作）、`"danger"`（危险/取消操作）

用户点击后，App 通过 `agent.submitResponse` 返回结果：
```json
{
  "response_type": "action_confirmation",
  "response_data": { "confirmation_id": "confirm_1a2b3c", "selected_action_id": "approve" }
}
```

#### `ui.singleSelect` — 单选列表

```json
{
  "jsonrpc": "2.0", "method": "ui.singleSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "select_1a2b3c",
    "prompt": "选择部署环境：",
    "options": [
      { "id": "dev", "label": "开发环境" },
      { "id": "staging", "label": "测试环境" },
      { "id": "prod", "label": "生产环境" }
    ]
  }
}
```

#### `ui.multiSelect` — 多选列表

```json
{
  "jsonrpc": "2.0", "method": "ui.multiSelect",
  "params": {
    "task_id": "task_abc123",
    "select_id": "mselect_1a2b3c",
    "prompt": "选择需要启用的功能：",
    "options": [
      { "id": "feature_a", "label": "功能 A" },
      { "id": "feature_b", "label": "功能 B" },
      { "id": "feature_c", "label": "功能 C" }
    ],
    "min_select": 1,
    "max_select": null
  }
}
```

`min_select`：最少选择数（默认 1）；`max_select`：最多选择数（null = 不限）

#### `ui.fileUpload` — 请求用户上传文件

```json
{
  "jsonrpc": "2.0", "method": "ui.fileUpload",
  "params": {
    "task_id": "task_abc123",
    "upload_id": "upload_1a2b3c",
    "prompt": "请上传需要分析的文档：",
    "accept_types": ["pdf", "doc", "docx", "txt"],
    "max_files": 3,
    "max_size_mb": 20
  }
}
```

#### `ui.form` — 结构化表单

```json
{
  "jsonrpc": "2.0", "method": "ui.form",
  "params": {
    "task_id": "task_abc123",
    "form_id": "form_1a2b3c",
    "title": "新建任务",
    "description": "请填写任务信息",
    "fields": [
      {
        "field_id": "title",
        "type": "text_input",
        "label": "任务名称",
        "placeholder": "输入任务名称...",
        "required": true,
        "max_lines": 1
      },
      {
        "field_id": "priority",
        "type": "single_select",
        "label": "优先级",
        "required": true,
        "options": [
          { "id": "high", "label": "高" },
          { "id": "medium", "label": "中" },
          { "id": "low", "label": "低" }
        ]
      },
      {
        "field_id": "tags",
        "type": "multi_select",
        "label": "标签",
        "required": false,
        "options": [
          { "id": "bug", "label": "Bug" },
          { "id": "feature", "label": "新功能" },
          { "id": "docs", "label": "文档" }
        ]
      },
      {
        "field_id": "description",
        "type": "text_input",
        "label": "详细描述",
        "placeholder": "描述任务详情...",
        "required": false,
        "max_lines": 5
      },
      {
        "field_id": "attachment",
        "type": "file_upload",
        "label": "附件",
        "required": false,
        "accept_types": ["png", "jpg", "pdf"],
        "max_files": 2,
        "max_size_mb": 10
      }
    ]
  }
}
```

**表单字段类型**：`"text_input"`、`"single_select"`、`"multi_select"`、`"file_upload"`

#### `ui.fileMessage` — 发送文件给用户

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

#### `ui.messageMetadata` — 折叠内容

```json
{
  "jsonrpc": "2.0", "method": "ui.messageMetadata",
  "params": {
    "task_id": "task_abc123",
    "collapsible": true,
    "collapsible_title": "推理过程",
    "auto_collapse": true
  }
}
```

使用此组件时，当前响应的文本内容将变为折叠区域，`collapsible_title` 作为折叠标题显示。

#### `ui.requestHistory` — 请求更多历史

```json
{
  "jsonrpc": "2.0", "method": "ui.requestHistory",
  "params": {
    "task_id": "task_abc123",
    "request_id": "hist_req_1a2b3c",
    "reason": "你提到了我们之前讨论过的项目，让我调取更多对话记录。",
    "requested_count": 40
  }
}
```

> 发送此通知后，停止生成文本。App 会发送包含补充历史的新 `agent.chat` 请求（见第 10 节）。

### 7.4 指令语法模式详解

如果你的 LLM 不支持 Function Calling，可以使用指令语法。将 `hub.getUIComponentTemplates` 返回的 `acp_directive_prompt` 注入到 system prompt，LLM 将在输出中嵌入如下格式的指令块：

```
这里是我的回复文本...

<<<directive
{
  "type": "action_confirmation",
  "prompt": "是否继续？",
  "actions": [
    {"id": "yes", "label": "继续", "style": "primary"},
    {"id": "no", "label": "取消", "style": "danger"}
  ]
}
>>>

后续文本...
```

**解析器实现（Python）：**

```python
class DirectiveStreamParser:
    """解析 LLM 输出中的 <<<directive ... >>> 块"""
    
    OPEN = "<<<directive"
    CLOSE = ">>>"
    
    def __init__(self):
        self._buffer = ""
        self._in_directive = False
        self._directive_buffer = ""
    
    def feed(self, chunk: str) -> list:
        """处理一个文本片段，返回事件列表"""
        events = []
        self._buffer += chunk
        
        while True:
            if not self._in_directive:
                idx = self._buffer.find(self.OPEN)
                if idx == -1:
                    # 没有指令开始标记，全部作为文本输出
                    # 保留末尾可能是指令开始的部分
                    safe_len = max(0, len(self._buffer) - len(self.OPEN))
                    if safe_len > 0:
                        events.append(("text", self._buffer[:safe_len]))
                        self._buffer = self._buffer[safe_len:]
                    break
                else:
                    # 输出指令之前的文本
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
        """流结束时调用，处理剩余内容"""
        events = []
        if not self._in_directive and self._buffer:
            events.append(("text", self._buffer))
            self._buffer = ""
        return events


# 使用示例
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
                    # 为没有 ID 字段的组件自动生成
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

### 7.5 处理用户交互响应

用户与 UI 组件交互后，App 发送 `agent.submitResponse`：

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

不同组件类型的 `response_data`：

| 组件 | response_data 格式 |
|------|-------------------|
| `action_confirmation` | `{ "confirmation_id": "...", "selected_action_id": "action_id" }` |
| `single_select` | `{ "select_id": "...", "selected_option_id": "opt_id" }` |
| `multi_select` | `{ "select_id": "...", "selected_option_ids": ["opt1", "opt2"] }` |
| `file_upload` | `{ "upload_id": "...", "uploaded_file_ids": [...] }` |
| `form` | `{ "form_id": "...", "field_values": { "field_id": "value", ... } }` |

回复示例：
```json
{ "jsonrpc": "2.0", "id": 5, "result": { "status": "received" } }
```

---

## 8. 文件传输

### 8.1 HTTP 文件服务（推荐方式）

最简单的方式：在你的 Agent 服务器上提供 HTTP 端点，发送 `ui.fileMessage` 带 URL：

```python
import os, uuid, mimetypes, time
from aiohttp import web

_file_registry = {}  # file_id -> {path, filename, mime_type, size}

async def serve_file_to_user(ws, task_id: str, file_path: str):
    """注册文件并通知 App 下载"""
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
    
    # 通知 App 有文件可下载
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
    """HTTP 文件下载端点"""
    file_id = request.match_info["file_id"]
    entry = _file_registry.get(file_id)
    if not entry or not os.path.exists(entry["path"]):
        return web.Response(status=404)
    return web.FileResponse(entry["path"], headers={
        "Content-Type": entry["mime_type"],
        "Content-Disposition": f'inline; filename="{entry["filename"]}"'
    })

# 注册路由：
# app.router.add_get("/files/{file_id}", handle_file_download)
```

### 8.2 WebSocket 二进制传输

对于无法提供公网 HTTP 服务的场景，可使用 WebSocket 二进制帧传输。

**二进制帧格式：**

```
┌────────────┬──────────────────┬──────────────────────────────┐
│  4 字节    │  12 字节         │  变长                        │
│  "FILE"    │  file_id（补零） │  文件数据块                  │
│  (魔数)    │                  │                              │
└────────────┴──────────────────┴──────────────────────────────┘
```

**传输流程：**

```
Agent                              App
  │── ui.fileMessage (有 file_id, 无 url) ──►│
  │◄── agent.requestFileData {file_id} ───────│
  │── Response: {filename, mime_type, size} ──►│
  │── file.transferStart 通知 ─────────────────►│
  │── binary frame (chunk 1) ──────────────────►│
  │── binary frame (chunk 2) ──────────────────►│
  │── binary frame (chunk N) ──────────────────►│
  │── file.transferComplete 通知 ───────────────►│
```

**Python 实现：**

```python
async def handle_request_file_data(ws, msg_id, params):
    import math
    file_id = params["file_id"]
    entry = _file_registry.get(file_id)
    if not entry:
        await ws.send_json({"jsonrpc": "2.0", "id": msg_id,
                            "error": {"code": -32003, "message": "File not found"}})
        return
    
    chunk_size = 65536  # 64KB
    total_size = entry["size"]
    chunk_count = math.ceil(total_size / chunk_size) if total_size > 0 else 1
    
    # 响应文件元数据
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {
            "file_id": file_id, "filename": entry["filename"],
            "mime_type": entry["mime_type"], "size": total_size,
            "chunk_size": chunk_size, "chunk_count": chunk_count
        }
    })
    
    # 发送 transferStart 通知
    await ws.send_json({
        "jsonrpc": "2.0", "method": "file.transferStart",
        "params": {"file_id": file_id, "filename": entry["filename"],
                   "mime_type": entry["mime_type"], "size": total_size,
                   "chunk_count": chunk_count}
    })
    
    # 构造帧头
    magic = b"FILE"
    file_id_bytes = file_id.encode("utf-8")[:12].ljust(12, b"\x00")
    header = magic + file_id_bytes
    
    # 发送文件数据
    with open(entry["path"], "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            await ws.send_bytes(header + chunk)
    
    # 发送完成通知
    await ws.send_json({
        "jsonrpc": "2.0", "method": "file.transferComplete",
        "params": {"file_id": file_id, "total_bytes": total_size}
    })
```

---

## 9. 任务生命周期管理

### 9.1 任务取消

用户点击"停止"按钮时，App 发送 `agent.cancelTask`：

```json
{
  "jsonrpc": "2.0", "method": "agent.cancelTask",
  "params": { "task_id": "task_abc123" }, "id": 4
}
```

你的 Agent 应：
1. 立即响应确认
2. 取消对应的 LLM 调用
3. 发送 `task.error`（错误码 `-32008` 表示任务取消）

```python
# 用 asyncio.Task 跟踪每个 agent.chat
_active_tasks = {}  # task_id -> asyncio.Task

# 收到 agent.chat 时
task = asyncio.create_task(handle_chat(ws, msg_id, params))
_active_tasks[params["task_id"]] = task

# 收到 agent.cancelTask 时
async def handle_cancel(ws, msg_id, params):
    task_id = params.get("task_id", "")
    t = _active_tasks.pop(task_id, None)
    if t:
        t.cancel()
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id,
        "result": {"task_id": task_id, "status": "cancelled"}
    })

# handle_chat 中捕获取消
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]
    try:
        # ... 正常处理 ...
    except asyncio.CancelledError:
        await ws.send_json({
            "jsonrpc": "2.0", "method": "task.error",
            "params": {"task_id": task_id, "message": "Task cancelled", "code": -32008}
        })
    finally:
        _active_tasks.pop(task_id, None)
```

### 9.2 消息回滚

用户点击"重新生成"时，App 发送 `agent.rollback`，要求删除最后一轮对话：

```json
{
  "jsonrpc": "2.0", "method": "agent.rollback",
  "params": { "session_id": "session_xyz", "message_id": "msg_001" }, "id": 6
}
```

你应从会话历史中删除最后一条 `assistant` 消息和最后一条 `user` 消息：

```python
async def handle_rollback(ws, msg_id, params):
    session_id = params.get("session_id", "")
    # 从对话历史中回滚
    history = conversation_manager.get(session_id)
    if history and history[-1]["role"] == "assistant":
        history.pop()
    if history and history[-1]["role"] == "user":
        history.pop()
    
    await ws.send_json({
        "jsonrpc": "2.0", "id": msg_id, "result": {"status": "ok"}
    })
```

### 9.3 完整消息时序图

```
App                                           Agent
 │                                              │
 │── auth.authenticate ────────────────────────►│
 │◄── {status: "authenticated"} ────────────────│
 │                                              │
 │── agent.chat {task_id, message} ────────────►│
 │◄── {task_id, status: "accepted"} ────────────│  ← 必须立即响应
 │◄── task.started ─────────────────────────────│
 │◄── ui.textContent (chunk 1) ─────────────────│
 │◄── ui.textContent (chunk 2) ─────────────────│
 │         ... （更多片段）...                  │
 │◄── ui.textContent (is_final=true) ───────────│  ← 必须发送
 │◄── task.completed ───────────────────────────│
 │                                              │
 │── ping ─────────────────────────────────────►│
 │◄── {pong: true} ─────────────────────────────│
```

**错误场景：**

```
 │── agent.chat ────────────────────────────────►│
 │◄── {status: "accepted"} ─────────────────────│
 │◄── task.started ─────────────────────────────│
 │◄── ui.textContent (部分内容) ─────────────────│
 │     ... 发生错误 ...                          │
 │◄── task.error {message: "...", code: -32603} ─│
```

**取消场景：**

```
 │── agent.chat ────────────────────────────────►│
 │◄── {status: "accepted"} ─────────────────────│
 │◄── task.started ─────────────────────────────│
 │◄── ui.textContent (部分内容) ─────────────────│
 │── agent.cancelTask ──────────────────────────►│
 │◄── {status: "cancelled"} ────────────────────│
 │◄── task.error {code: -32008} ────────────────│
```

---

## 10. 会话历史管理

### 10.1 基本原则

App 以 `session_id` 管理对话。你的 Agent 应：

1. **首次接触某 session_id**：用 `history` 数组初始化本地会话状态
2. **后续消息**：追加到本地历史（不依赖 `history` 字段）
3. **检测历史缺口**：对比 `total_message_count` 与本地计数

```python
class ConversationManager:
    def __init__(self, max_history_pairs=20):
        self._sessions = {}  # session_id -> list of {"role", "content"}
        self._max_pairs = max_history_pairs
    
    def has_session(self, session_id: str) -> bool:
        return session_id in self._sessions
    
    def init_from_history(self, session_id: str, history: list):
        """首次使用 App 提供的历史初始化会话"""
        if session_id not in self._sessions:
            valid = [
                {"role": m["role"], "content": m["content"]}
                for m in history
                if m.get("role") in ("user", "assistant") and m.get("content")
            ]
            self._sessions[session_id] = valid
    
    def add_user(self, session_id: str, content: str):
        msgs = self._sessions.setdefault(session_id, [])
        msgs.append({"role": "user", "content": content})
        self._trim(session_id)
    
    def add_assistant(self, session_id: str, content: str):
        msgs = self._sessions.setdefault(session_id, [])
        msgs.append({"role": "assistant", "content": content})
        self._trim(session_id)
    
    def get_messages(self, session_id: str) -> list:
        return list(self._sessions.get(session_id, []))
    
    def prepend_older(self, session_id: str, older_messages: list):
        """前置更早的历史消息（历史补充场景）"""
        if session_id in self._sessions:
            valid = [
                {"role": m["role"], "content": m["content"]}
                for m in older_messages
                if m.get("role") in ("user", "assistant") and m.get("content")
            ]
            self._sessions[session_id] = valid + self._sessions[session_id]
    
    def rollback(self, session_id: str):
        msgs = self._sessions.get(session_id, [])
        if msgs and msgs[-1]["role"] == "assistant":
            msgs.pop()
        if msgs and msgs[-1]["role"] == "user":
            msgs.pop()
    
    def _trim(self, session_id: str):
        msgs = self._sessions[session_id]
        max_msgs = self._max_pairs * 2
        if len(msgs) > max_msgs:
            self._sessions[session_id] = msgs[-max_msgs:]
```

### 10.2 处理历史补充

当你发送 `ui.requestHistory` 后，App 会发送一个补充请求：

```json
{
  "method": "agent.chat",
  "params": {
    "history_supplement": true,
    "additional_history": [ ... 更早的消息 ... ],
    "original_question": "用户原始问题的文本"
  }
}
```

处理方式：

```python
async def handle_chat(ws, msg_id, params):
    task_id = params["task_id"]
    session_id = params.get("session_id", task_id)
    
    # 初始化或补充历史
    if params.get("history_supplement"):
        additional = params.get("additional_history", [])
        if additional:
            conv_mgr.prepend_older(session_id, additional)
        # 删除上次未完成的 assistant 回复
        msgs = conv_mgr.get_messages(session_id)
        if msgs and msgs[-1]["role"] == "assistant":
            msgs.pop()
        # 不新增用户消息，直接用已有历史重新生成
        messages = conv_mgr.get_messages(session_id)
    else:
        if not conv_mgr.has_session(session_id) and params.get("history"):
            conv_mgr.init_from_history(session_id, params["history"])
        conv_mgr.add_user(session_id, params.get("message", ""))
        messages = conv_mgr.get_messages(session_id)
    
    # ... 继续调用 LLM ...
```

---

## 11. Hub 数据查询（Agent → App）

你的 Agent 可以主动向 App 请求数据。这些是**请求**（有 `id`），需要等待响应。

### 11.1 发送 Hub 请求的通用模式

```python
async def hub_request(ws, pending_requests: dict, method: str, params=None, timeout=10.0):
    """发送请求到 App 并等待响应"""
    req_id = str(uuid.uuid4())
    loop = asyncio.get_running_loop()
    future = loop.create_future()
    pending_requests[req_id] = future
    
    msg = {"jsonrpc": "2.0", "method": method, "id": req_id}
    if params:
        msg["params"] = params
    await ws.send_json(msg)
    
    try:
        return await asyncio.wait_for(future, timeout=timeout)
    except asyncio.TimeoutError:
        pending_requests.pop(req_id, None)
        raise

# 在消息循环中处理响应（有 id，无 method）：
elif msg_id is not None and method is None:
    future = pending_requests.pop(msg_id, None)
    if future and not future.done():
        if data.get("error"):
            future.set_exception(RuntimeError(data["error"]["message"]))
        else:
            future.set_result(data.get("result"))
```

### 11.2 获取会话列表

```json
// Agent 发送
{ "jsonrpc": "2.0", "method": "hub.getSessions", "id": "req_001" }

// App 响应
{
  "jsonrpc": "2.0", "id": "req_001",
  "result": {
    "sessions": [
      {
        "id": "session_abc",
        "title": "会话标题",
        "agent_id": "agent_xyz",
        "created_at": 1700000000000,
        "updated_at": 1700000001000
      }
    ]
  }
}
```

### 11.3 获取会话消息

```json
// Agent 发送
{
  "jsonrpc": "2.0",
  "method": "hub.getSessionMessages",
  "params": { "session_id": "session_abc", "limit": 50 },
  "id": "req_002"
}
```

### 11.4 获取 Agent 列表

```json
{ "jsonrpc": "2.0", "method": "hub.getAgentList", "id": "req_003" }
```

### 11.5 获取 Hub 信息

```json
{ "jsonrpc": "2.0", "method": "hub.getHubInfo", "id": "req_004" }
```

### 11.6 获取附件内容

当需要获取某条消息中附件的完整数据时：

```json
{
  "jsonrpc": "2.0",
  "method": "hub.getAttachmentContent",
  "params": { "attachment_id": "att_abc123" },
  "id": "req_005"
}
```

### 11.7 发起主动聊天

Agent 可以主动向用户发起新会话（需要 App 用户授权）：

```json
{
  "jsonrpc": "2.0",
  "method": "hub.initiateChat",
  "params": {
    "message": "你好，我有一些重要信息要告诉你",
    "agent_id": "my-agent-id"
  },
  "id": "req_006"
}
```

---

## 12. 群组聊天支持

当多个 Agent 参与同一会话时，`agent.chat` 会携带 `group_context` 字段：

```json
{
  "group_context": {
    "group_id": "group_abc",
    "group_name": "我的工作群组",
    "members": [
      { "id": "agent_1", "name": "Agent A", "type": "agent" },
      { "id": "agent_2", "name": "Agent B", "type": "agent" },
      { "id": "user_001", "name": "用户", "type": "user" }
    ],
    "current_agent_id": "agent_1"
  }
}
```

在群组场景中：
- 根据 `current_agent_id` 判断当前轮次是否轮到你回复
- `system_prompt` 字段会包含群组上下文信息
- 多个 Agent 的回复会依次显示在同一会话中

---

## 13. 完整实现示例

以下是一个生产就绪的 Python Agent 骨架，集成了所有核心功能：

```python
#!/usr/bin/env python3
"""
Shepaw ACP Remote Agent - 生产级骨架
支持：流式响应、任务取消、会话历史、UI 组件、文件服务
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


# ─── JSON-RPC 辅助函数 ────────────────────────────────────────────────────────

def rpc_ok(id, result=None):
    return {"jsonrpc": "2.0", "id": id, "result": result or {}}

def rpc_err(id, code: int, message: str):
    return {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}

def notify(method: str, params: dict):
    return {"jsonrpc": "2.0", "method": method, "params": params}


# ─── 会话历史管理 ─────────────────────────────────────────────────────────────

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


# ─── 文件注册表 ───────────────────────────────────────────────────────────────

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


# ─── Agent 主类 ───────────────────────────────────────────────────────────────

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
        self._active_tasks: dict = {}   # task_id -> asyncio.Task
        self._pending: dict = {}        # req_id -> asyncio.Future (hub requests)
        self._ui_templates: Optional[dict] = None

    # ─── WebSocket 处理入口 ──────────────────────────────────────────────────

    async def ws_handler(self, request: web.Request) -> web.WebSocketResponse:
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        authed = False
        print(f"[连接] 新客户端连接")

        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    await self._handle_text(ws, msg.data, authed,
                                            lambda: authed,
                                            lambda v: exec(f"authed = {v}"))
                    # 由于 Python 闭包限制，改用列表传递 authed 状态
                elif msg.type == aiohttp.WSMsgType.BINARY:
                    pass  # 二进制帧（文件传输）由 App 发起，无需处理
                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                    break
        except Exception as e:
            print(f"[错误] WebSocket 处理异常: {e}")
        finally:
            for t in self._active_tasks.values():
                t.cancel()
            self._active_tasks.clear()
            print("[连接] 客户端断开")

        return ws

    async def _handle_all(self, request: web.Request) -> web.WebSocketResponse:
        """改进版 WebSocket 处理，用列表承载 authed 状态"""
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        state = {"authed": False}
        print("[连接] 新客户端连接")

        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    data = json.loads(msg.data)
                    method = data.get("method")
                    mid = data.get("id")
                    params = data.get("params") or {}

                    # 请求（有 id 且有 method）
                    if mid is not None and method is not None:
                        await self._dispatch_request(ws, method, mid, params, state)

                    # 响应（有 id，无 method）：这是对我们之前发出的 hub.* 请求的回复
                    elif mid is not None and method is None:
                        fut = self._pending.pop(mid, None)
                        if fut and not fut.done():
                            if data.get("error"):
                                fut.set_exception(RuntimeError(str(data["error"])))
                            else:
                                fut.set_result(data.get("result"))

                elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSE):
                    break

        except Exception as e:
            print(f"[错误] {e}")
        finally:
            for t in self._active_tasks.values():
                t.cancel()
            self._active_tasks.clear()

        return ws

    async def _dispatch_request(self, ws, method: str, mid, params: dict, state: dict):
        """分发处理各类请求"""
        authed = state["authed"]

        # 认证
        if method == "auth.authenticate":
            if not self.token or params.get("token") == self.token:
                state["authed"] = True
                await ws.send_json(rpc_ok(mid, {"status": "authenticated"}))
            else:
                await ws.send_json(rpc_err(mid, -32000, "Authentication failed"))
            return

        # 心跳（不需要认证）
        if method == "ping":
            await ws.send_json(rpc_ok(mid, {"pong": True}))
            return

        if not authed:
            await ws.send_json(rpc_err(mid, -32001, "Not authenticated"))
            return

        # Agent 卡片
        if method == "agent.getCard":
            await ws.send_json(rpc_ok(mid, {
                "agent_id": "my-remote-agent",
                "name": self.name,
                "description": self.description,
                "version": self.version,
                "capabilities": ["chat", "streaming", "interactive_messages", "file_transfer"],
                "supported_protocols": ["acp"],
            }))

        # 核心对话
        elif method == "agent.chat":
            task_id = params.get("task_id", str(uuid.uuid4()))
            task = asyncio.create_task(self._handle_chat(ws, mid, params))
            self._active_tasks[task_id] = task

        # 取消任务
        elif method == "agent.cancelTask":
            task_id = params.get("task_id", "")
            t = self._active_tasks.pop(task_id, None)
            if t:
                t.cancel()
            await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "cancelled"}))

        # 提交交互响应
        elif method == "agent.submitResponse":
            await ws.send_json(rpc_ok(mid, {"status": "received"}))
            rd = params.get("response_data", {})
            for key in ("confirmation_id", "select_id", "upload_id", "form_id"):
                cid = rd.get(key)
                if cid:
                    fut = self._pending.pop(cid, None)
                    if fut and not fut.done():
                        fut.set_result(rd)

        # 消息回滚
        elif method == "agent.rollback":
            self._conv.rollback(params.get("session_id", ""))
            await ws.send_json(rpc_ok(mid, {"status": "ok"}))

        # 文件数据请求
        elif method == "agent.requestFileData":
            await self._handle_request_file_data(ws, mid, params)

        else:
            await ws.send_json(rpc_err(mid, -32601, f"Method not found: {method}"))

    # ─── 核心对话处理 ────────────────────────────────────────────────────────

    async def _handle_chat(self, ws, mid, params: dict):
        task_id = params.get("task_id", str(uuid.uuid4()))
        session_id = params.get("session_id", task_id)
        message = params.get("message", "")
        attachments = params.get("attachments") or []

        # Step 1: 立即确认
        await ws.send_json(rpc_ok(mid, {"task_id": task_id, "status": "accepted"}))
        await ws.send_json(notify("task.started", {
            "task_id": task_id, "started_at": datetime.now().isoformat()
        }))

        try:
            # 处理历史
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

            # ─────────────────────────────────────────────────────────────
            # 在这里实现你的 LLM 调用逻辑
            # 示例：简单的 Echo 回复
            # ─────────────────────────────────────────────────────────────
            reply_text = await self._call_llm(message, messages, attachments)

            # 流式发送（如果 LLM 支持 streaming，这里可以改为 async for chunk in ...）
            chunk_size = 10
            for i in range(0, len(reply_text), chunk_size):
                chunk = reply_text[i:i + chunk_size]
                await ws.send_json(notify("ui.textContent", {
                    "task_id": task_id, "content": chunk, "is_final": False
                }))
                await asyncio.sleep(0.02)

            # 保存 assistant 回复到历史
            self._conv.add_assistant(session_id, reply_text)

            # Step 4: 标记文本流结束（必须！）
            await ws.send_json(notify("ui.textContent", {
                "task_id": task_id, "content": "", "is_final": True
            }))

            # Step 5: 任务完成
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
        在这里实现你的 LLM 调用。
        返回完整回复文本（非流式）。
        如需流式，改为 async generator。
        """
        # 示例：Echo 回复
        if attachments:
            att_names = [a["file_name"] for a in attachments]
            return f"收到你的消息：{message}\n附件：{', '.join(att_names)}"
        return f"收到你的消息：{message}"

    # ─── 文件数据传输 ─────────────────────────────────────────────────────────

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

    # ─── Hub 请求辅助 ─────────────────────────────────────────────────────────

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

    # ─── HTTP 文件服务 ────────────────────────────────────────────────────────

    async def handle_file_serve(self, request: web.Request) -> web.Response:
        file_id = request.match_info.get("file_id", "")
        entry = self._files.get(file_id)
        if not entry or not os.path.exists(entry["path"]):
            return web.Response(status=404, text="File not found")
        return web.FileResponse(entry["path"], headers={
            "Content-Type": entry["mime_type"],
            "Content-Disposition": f'inline; filename="{entry["filename"]}"'
        })

    # ─── 启动 ─────────────────────────────────────────────────────────────────

    def run(self, host: str = "0.0.0.0"):
        app = web.Application()
        app.router.add_get("/acp/ws", self._handle_all)
        app.router.add_get("/files/{file_id}", self.handle_file_serve)
        print(f"[启动] {self.name} 监听 {host}:{self.port}")
        print(f"[启动] WebSocket 端点: ws://{host}:{self.port}/acp/ws")
        web.run_app(app, host=host, port=self.port)


# ─── 入口 ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    agent = MyAgent(
        token=os.getenv("AGENT_TOKEN", "my-secret-token"),
        name="My Remote LLM Agent",
        description="基于 Shepaw ACP 协议的远程 LLM Agent",
        version="1.0.0",
        port=int(os.getenv("PORT", "8080")),
    )
    agent.run()
```

**运行：**

```bash
pip install aiohttp
AGENT_TOKEN=my-secret-token python my_agent.py
```

---

## 14. 错误码参考

### JSON-RPC 标准错误

| 错误码 | 名称 | 说明 |
|--------|------|------|
| `-32700` | Parse error | 收到无效 JSON |
| `-32600` | Invalid request | JSON 格式不是合法的 JSON-RPC 请求 |
| `-32601` | Method not found | 请求的方法不存在 |
| `-32602` | Invalid params | 参数无效 |
| `-32603` | Internal error | 通用服务器内部错误 |

### 应用级错误

| 错误码 | 名称 | 说明 |
|--------|------|------|
| `-32000` | Authentication failed | Token 无效或缺失 |
| `-32001` | Unauthorized | 已认证但无权限执行该操作 |
| `-32002` | Permission denied | 缺少特定权限 |
| `-32003` | Not found | 任务、文件、会话等资源不存在 |
| `-32004` | Pending approval | 操作需要用户审批 |
| `-32005` | Session not found | 对话会话不存在 |
| `-32006` | Task failed | 任务执行失败 |
| `-32007` | Timeout | 操作超时 |
| `-32008` | Task cancelled | 任务被用户取消（用于 CancelledError 场景） |

---

## 15. 在 Shepaw 中注册你的 Agent

1. 打开 Shepaw App
2. 进入 **设置 → Agents → 添加 Agent**
3. 填写以下信息：
   - **Agent 名称**：显示名称（可自定义）
   - **WebSocket 地址**：`ws://your-host:8080/acp/ws`
   - **Token**：你 Agent 服务设置的认证 Token
   - **协议**：选择 `ACP`
4. 保存后，App 会立即尝试连接并发送认证请求
5. 连接成功后，Agent 状态显示为"在线"

**本地开发提示**：
- iOS/Android 设备连接同局域网电脑时，使用内网 IP（如 `ws://192.168.1.100:8080/acp/ws`）
- macOS/Windows 桌面版可以使用 `ws://localhost:8080/acp/ws`
- 如需公网访问，可以使用 `ngrok`、`frp` 等内网穿透工具

---

## 16. 常见问题

### Q: 最少需要实现哪些方法？

只需实现这 3 个方法即可运行：
1. `auth.authenticate` — 验证 Token 并返回成功
2. `ping` — 返回 pong
3. `agent.chat` — 确认、发 `task.started`、流式 `ui.textContent`、`is_final=true`、`task.completed`

### Q: `ui.textContent` 的 `is_final=true` 必须发吗？

**必须发送**。App 依赖此信号关闭消息气泡。如果不发送，App 会一直显示"加载中"状态，最终超时。

### Q: 如何同时处理多个对话？

每个 `agent.chat` 请求都有独立的 `task_id`，使用 `asyncio.create_task()` 为每个请求创建独立的协程，以 `task_id` 为键存储在字典中，这样可以同时处理多个请求并支持单独取消。

### Q: WebSocket 断开后如何处理？

App 会自动重连（最多 5 次，指数退避）。你的 Agent 应：
- 断开时取消所有正在进行的任务
- 清理 pending 的 hub 请求 futures
- 重新连接时接受全新的认证流程（不要假设之前的状态）

### Q: 如何在不部署 HTTP 服务的情况下传输文件？

使用 WebSocket 二进制帧传输（见第 8.2 节）。发送 `ui.fileMessage` 时不要包含 `url` 字段，只包含 `file_id`。App 会发送 `agent.requestFileData` 请求，然后你通过二进制帧传输文件数据。

### Q: 如何测试我的 Agent 不用 App？

使用 `wscat`（命令行 WebSocket 客户端）：

```bash
npm install -g wscat
wscat -c ws://localhost:8080/acp/ws

# 发送认证
> {"jsonrpc":"2.0","method":"auth.authenticate","params":{"token":"my-secret-token"},"id":1}

# 发送心跳
> {"jsonrpc":"2.0","method":"ping","params":{},"id":2}

# 发送消息
> {"jsonrpc":"2.0","method":"agent.chat","params":{"task_id":"t1","session_id":"s1","message":"你好","user_id":"u1","message_id":"m1"},"id":3}
```

### Q: `history` 字段什么时候会包含内容？

- 新会话（Agent 不知道该 `session_id`）：包含完整历史
- App 检测到历史缺口：也会附带历史
- 同一 WebSocket 连接内的后续消息：通常不包含（Agent 自己维护）

### Q: `ui_component_version` 有什么用？

标记 App 的 UI 组件注册表版本。如果两次请求之间版本发生变化，说明 App 升级了，你需要重新调用 `hub.getUIComponentTemplates` 更新缓存的组件定义和 directive prompt。

---

## 附录：协议方法速查

### App → Agent 请求

| 方法 | 说明 |
|------|------|
| `auth.authenticate` | 认证握手 |
| `agent.chat` | 发送消息（核心） |
| `agent.cancelTask` | 取消运行中的任务 |
| `agent.submitResponse` | 提交 UI 组件交互结果 |
| `agent.rollback` | 回滚最后一轮对话 |
| `agent.getCard` | 获取 Agent 元数据卡片 |
| `agent.requestFileData` | 请求 WebSocket 文件传输 |
| `ping` | 心跳检测 |

### Agent → App 通知

| 方法 | 说明 |
|------|------|
| `ui.textContent` | 流式文本（`is_final=true` 标记结束） |
| `ui.actionConfirmation` | 操作按钮组件 |
| `ui.singleSelect` | 单选列表组件 |
| `ui.multiSelect` | 多选列表组件 |
| `ui.fileUpload` | 请求用户上传文件 |
| `ui.form` | 结构化表单组件 |
| `ui.fileMessage` | 向用户发送文件 |
| `ui.messageMetadata` | 折叠内容元数据 |
| `ui.requestHistory` | 请求更多会话历史 |
| `task.started` | 任务已开始 |
| `task.completed` | 任务已完成 |
| `task.error` | 任务失败/取消 |
| `file.transferStart` | 文件传输开始 |
| `file.transferComplete` | 文件传输完成 |
| `file.transferError` | 文件传输失败 |

### Agent → App 请求（Hub）

| 方法 | 说明 |
|------|------|
| `hub.getUIComponentTemplates` | 获取 UI 组件定义和 directive prompt |
| `hub.getSessions` | 获取会话列表 |
| `hub.getSessionMessages` | 获取会话消息记录 |
| `hub.getAgentList` | 获取已注册的 Agent 列表 |
| `hub.getHubInfo` | 获取 Hub 基本信息 |
| `hub.getAttachmentContent` | 获取附件完整内容 |
| `hub.initiateChat` | 主动发起新会话 |

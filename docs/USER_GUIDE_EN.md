# Shepaw User Guide

> She can be your AI spirit pet. The longer you spend together, the better she understands you — and the more you can trust her.
> Everyone deserves multiple AI assistants, and one Shepaw.
> **Shepaw — she helps you navigate the world of AI.**

Shepaw is a local-first AI Agent Hub that helps you collaborate with multiple AI assistants to accomplish tasks. This guide will walk you through all the features the app has to offer.

---

> **Language / 语言:** **English** | [中文](USER_GUIDE.md)

## Table of Contents
1. [Quick Start](#quick-start)
2. [Core Features](#core-features)
   - [1. Adding and Managing Agents](#1-adding-and-managing-agents)
   - [2. Chat & Messaging](#2-chat--messaging)
   - [3. Group Chat](#3-group-chat)
3. [Advanced Features](#advanced-features)
   - [1. Multimodal Routing](#1-multimodal-routing)
   - [2. System Tools & Skill Packages](#2-system-tools--skill-packages)
   - [3. Permission Management & Audit](#3-permission-management--audit)
4. [Security & Privacy](#security--privacy)
   - [1. Password & Biometrics](#1-password--biometrics)
   - [2. Local Data Storage](#2-local-data-storage)
   - [3. Data Export & Backup](#3-data-export--backup)
   - [4. Deleting Data](#4-deleting-data)
5. [FAQ](#faq)
6. [Quick Reference](#quick-reference)

---

## Quick Start

### First Launch

1. **Set a Master Password**
   - On first launch, you will be prompted to create a master password
   - The master password protects all sensitive data (API keys, chat history, etc.)
   - Use at least 8 characters, including uppercase, lowercase, and numbers

2. **Enable Biometrics (optional)**
   - After setting your master password, you can enable Face ID, Touch ID, or fingerprint authentication
   - This lets you unlock the app without typing your password each time

3. **Add Your First Agent**
   - **Desktop:** the app detects whether Agent Hub (`shepaw-hub`) is already on this computer. If it is, you are prompted to join so Hub agents appear in Contacts. If it is not, the app can install Agent Hub and open the dashboard so you can add instances (engine + working directory).
   - Sidebar: **Contacts** (agents / groups / paired devices), **Store** (backups), **Settings**
   - You can also tap **"Add Agent"** from home or Contacts
   - Choose a **Local LLM Agent** or a **Remote Agent** (see below)

---

## Core Features

### 1. Adding and Managing Agents

#### 1.1 Local LLM Agent
A local agent runs AI models directly on your device without requiring a network connection.

**Supported AI Providers:**
- **OpenAI** — GPT-4, GPT-4o, GPT-3.5 Turbo (API key required)
- **Anthropic Claude** — Claude 3, Claude 2 (API key required)
- **Google Gemini** — Gemini Pro, Gemini Vision (API key required)
- **DeepSeek** — DeepSeek API (API key required)
- **Tencent Cloud TokenHub** — one platform aggregating 18+ models including Tencent Hunyuan, DeepSeek, GLM, Kimi, MiniMax and Qwen (API key required)
- **Ollama** — Locally deployed models (no network required)
- Any other provider with an OpenAI-compatible API

**About TokenHub regions:** TokenHub does not support cross-region calls. Set the API Base that matches the region your service is provisioned in:

| Region | API Base |
|--------|----------|
| Guangzhou / Chinese mainland | `https://tokenhub.tencentmaas.com/v1` (fallback `https://tokenhub.tencentmaas.cn/v1`) |
| Singapore | `https://tokenhub-intl.tencentmaas.com/v1` |
| Silicon Valley | `https://tokenhub-us.tencentmaas.com/v1` |

Selecting the TokenHub preset pre-fills the Guangzhou address; if you are provisioned in Singapore or Silicon Valley, edit the API Base field to the matching URL above.<br>
Model IDs are cross-vendor (e.g. `hy3`, `deepseek-v4-pro`, `glm-5.3`, `kimi-k3`, `minimax-m3`, `qwen3.5-flash`; vision model `hy-vision-2.0-instruct`). After entering your key, tap "Fetch TokenHub model list" to pull the model IDs available in your region and pick one.

**Setup Steps:**
1. Tap **"+ Add Agent"** → **"Local LLM Agent"**
2. Enter an agent name (e.g., "ChatGPT")
3. Select the LLM provider
4. Enter your API key (or Ollama server URL)
5. Choose a model and configure parameters (temperature, max tokens, etc.)
6. Tap **"Save"**

#### 1.2 Remote Agent (via ACP Protocol)
A remote agent runs on a remote server and talks to your device over ACP v2.1 (WebSocket + Noise, **no shared Token**).

**Setup Steps:**
1. Tap **"+ Add Agent"** → **"Remote Agent"**
2. **Recommended:** tap the QR icon in the endpoint URL field and scan the `shepaw://pair` code from `shepaw-acp-proxy pair` / `shepaw-hub pair`
3. Or paste the short pairing code from gateway `enroll`; or fill a `ws://` / `wss://` endpoint and have the operator `peers add` this device's public key
4. **Agent ID** is optional
5. Tap **"Save"**

**Advantages of Remote Agents:**
- Access to system tools (file operations, process execution, etc.)
- Support for custom skill packages
- Suitable for enterprise deployments and team collaboration

---

### 2. Chat & Messaging

#### 2.1 Starting a Conversation
1. Select an agent from the home screen
2. Type your question or instruction in the input box
3. Tap **Send** or press `Enter`
4. The agent will respond in real-time via streaming

#### 2.2 Rich Message Composition
While chatting, you can attach:
- **Text** — Markdown formatting is supported
- **Images** — Tap 📷 to upload (JPG, PNG supported)
- **Files** — Tap 📎 to attach any file
- **Voice** — Tap 🎤 to record an audio message
- **Emoji** — Tap 😊 to open the emoji picker
- **@Mention** — In group chats, use `@agentname` to address a specific agent

#### 2.3 Message Actions
On any message, you can:
- **Copy** — Copy the message content to clipboard
- **Reply** — Quote the message in your reply
- **Delete** — Remove the message
- **Search** — Use the search function to find messages

#### 2.4 Conversation Management
- **New Conversation** — Tap **"+ New Chat"** to start fresh
- **View History** — All past conversations appear in the left sidebar
- **Delete Conversation** — Long-press a conversation name and select Delete
- **Search Messages** — Use the search bar to find past messages quickly

---

### 3. Group Chat

Group chat lets you collaborate with multiple agents simultaneously.

#### 3.1 Creating a Group
1. Tap **"+ Create Group"**
2. Enter a group name
3. Select an **Admin Agent** (coordinator) and at least two **Member Agents**
4. Choose an orchestration mode (see below)
5. Tap **"Create"**

#### 3.2 Two Orchestration Modes

**Mode 1: Standard (Round-Robin)**
- The Admin Agent coordinates multiple member agents to take turns in the discussion
- Best for tasks that benefit from multiple perspectives
- Maximum rounds is configurable (default: 50)

**Mode 2: Flow Mode**
- The Admin generates a multi-stage execution plan (Stage 1 → Stage 2 → ...)
- The plan appears in the conversation first; you review, edit, or skip individual tasks
- Once you confirm, the system drives each stage in sequence automatically
- You can pause, resume, skip a stage, or abort at any time
- Best for complex multi-step workflows

#### 3.3 Sending Messages in a Group
1. Open a group chat
2. Type your message in the input box
3. Use `@agentname` to direct a message to a specific agent
4. Tap Send

#### 3.4 Managing Execution Plans (Flow Mode)
- **Review Tasks** — Inspect the plan generated by Admin; each task can be reviewed individually
- **Edit Tasks** — Tap a task card to modify its content
- **Skip Tasks** — Mark a task as skipped
- **Confirm & Execute** — Once satisfied, tap **"Confirm & Execute"**
- **Pause / Resume** — You can pause or resume execution at any time
- **View Results** — Live results are displayed as each task completes

---

## Advanced Features

### 1. Multimodal Routing

Automatically route different content types to the most capable AI model.

**Configuration:**
1. Go to **Settings** → **Model Management** to create or import global model definitions
2. On each agent's detail page, assign those definitions per modality (text / image / audio / video)
3. When you send a message of that type, the router picks the assigned model

---

### 2. System Tools & Skill Packages

#### 2.1 System Tools (Remote Agents)
Remote agents can invoke local system tools:
- **File Operations** — Read, write, delete files
- **Process Execution** — Run shell commands (bash, Python, etc.)
- **System Info** — Query CPU, memory, disk usage, and more

**How to Use:**
- Simply ask the agent in chat (e.g., "Create a file on my desktop")
- A permission confirmation dialog will appear if the operation requires it
- Approve the request to proceed

#### 2.2 Importing and Managing Skill Packages
Skill packages are custom bundles that extend an agent's capabilities.

**Import a Skill Package:**
1. Go to **Settings** → **Skill Management** and import from a local ZIP or URL
2. Then open Agent Details → **"Skill Packages"** and enable the skills that agent should use
3. Skills that are not checked are not injected

---

### 3. Permission Management & Audit

Shepaw applies permission controls to all sensitive operations.

#### 3.1 Permission Levels
- **SAFE** — Low-risk operations, executed automatically
- **WARNING** — Operations requiring user confirmation
- **DANGEROUS** — High-risk operations requiring explicit approval

#### 3.2 Permissions & CLI Toggles
- When an agent calls a tool, the approval record appears **in the chat** (there is no Settings → Permissions & Audit page)
- Global CLI / OS tools: **Settings** → **CLI Management**
- Per agent: Details → **CLI Commands** (restrict the command set and/or require approval before each run)
- A restricted allowlist also trims the shepaw tool `namespace` enum; if only specific commands such as `store.write` are enabled, the `subcommand` enum is trimmed too. The execution gate still enforces it. Everyday store I/O (`store`, except `declare` and `write --file` from a host path) and `help` skip approval; other commands show an in-chat approval card you can tap later, or allow for the rest of the session. Non-safe `os` tools always confirm. Remote ACP agents use `hub.cli.execute` under the same rules. Agent Hub engines use the local `shepaw` shim: this device's pouch stays on the Hub, everything else is forwarded to the paired App gate — not `hub.cli.execute`.
- **Peer inbound is separate**: when a paired device talks to a local agent, `PeerBoundaryConfig` still denies `os.*` and host memory writes. That deny-list is not merged into the per-agent CLI allowlist — an empty allowlist does not lift the inbound peer boundary.

#### 3.3 Inference Logs
1. Go to **Settings** → **Inference Log**
2. Review AI call statistics:
   - Token usage
   - Average response time
   - Error records
   - Per-agent breakdown
3. Export logs as CSV or JSON

---

## Security & Privacy

### 1. Password & Biometrics

#### 1.1 Setting a Master Password
1. Go to **Settings** → **Security** → **Password**
2. Tap **"Set Master Password"**
3. Enter your new password (8+ characters recommended)
4. Confirm the password

#### 1.2 Changing Your Password
1. Go to **Settings** → **Security** → **Password**
2. Tap **"Change Password"**
3. Enter your current password
4. Enter and confirm the new password

#### 1.3 Enabling Biometrics
1. Go to **Settings** → **Security** → **Biometrics**
2. Tap **"Enable Face ID"** or **"Enable Fingerprint"**
3. Complete setup following the system prompts
4. Biometrics will be used to unlock the app on next launch

---

### 2. Local Data Storage

All data is stored on your device by default:
- **Chat history** — Local SQLite database
- **Agent configuration** — Encrypted API keys
- **User settings** — Local config files

**Privacy Highlights:**
- No cloud sync (unless you export manually)
- Offline access to local agents
- You maintain full control of your data

---

### 3. Data Export & Backup

Backup lives in **Nexus Pouch → Backup & Restore** (encrypted snapshots), not in Settings.

#### 3.1 Create a snapshot
1. Go to **Nexus Pouch** → **Backup & Restore**
2. Tap **"Snapshot now"** and enter your master password
3. On a snapshot row, tap **"Export"** to save it to a local folder

#### 3.2 Restore from a snapshot
1. Go to **Nexus Pouch** → **Backup & Restore**
2. Choose a verified snapshot and tap **"Restore"**
3. Enter the password; restore fully replaces current data (no merge)

---

### 4. Deleting Data

#### 4.1 Delete a Single Conversation
- Long-press a conversation in the list
- Select **"Delete"**

#### 4.2 Delete all app data
1. Go to **Nexus Pouch** → **Backup & Restore**
2. Create and export a snapshot first
3. In **Danger zone**, tap **"Clear all app data"**
4. Type `DELETE` to confirm
5. **Warning: This cannot be undone.** App lock password and device identity are kept.

---

## FAQ

### Q1: How do I connect to a local Ollama model?
**A:**
1. Install Ollama on your computer (ollama.ai)
2. Pull a model: `ollama pull llama2`
3. In Shepaw, add a Local LLM Agent and choose Ollama
4. Enter the server URL: `http://localhost:11434`
5. Tap **"Test Connection"** to verify

### Q2: Can I edit the plan the Admin generates?
**A:** Yes. In Flow Mode the Admin's plan appears as a card in the conversation — you can review each task, edit its content, or mark it skipped. The system starts running only after you confirm, and you can still pause, resume, or abort while it runs.

### Q3: How can I improve chat response speed?
**A:**
- Use a local LLM model (e.g., Ollama) to eliminate network latency
- Reduce file sizes in your messages (compress images and files)
- Streaming responses are enabled by default — keep this on
- Disable unnecessary multimodal analysis if not needed

### Q4: How are my API keys kept secure?
**A:**
- All API keys are encrypted using your master password and stored locally
- Never share your master password or backup files
- Rotate API keys regularly
- Use a strong password (8+ characters with mixed case and numbers)

### Q5: Can I use the app offline?
**A:**
- Local LLM agents (e.g., Ollama) work fully offline
- Cloud-based agents (OpenAI, Claude, etc.) require an internet connection
- Browsing chat history and accessing settings works offline

### Q6: How do I delete an agent?
**A:**
1. Go to the agent list
2. Long-press the agent you want to remove
3. Select **"Delete"**
4. Confirm — note that associated chat history will be retained

### Q7: What does the Admin Agent do in a group chat?
**A:**
The Admin Agent is responsible for:
- Analyzing your requirements
- Generating execution plans (Flow Mode)
- Coordinating the work of other agents
- Consolidating and summarizing final results

### Q8: How do I update an agent's configuration?
**A:**
1. Open the agent's detail page
2. Tap the **"Edit"** button
3. Update the configuration (API key, model, parameters, etc.)
4. Tap **"Save"**

### Q9: What file formats are supported?
**A:**
- **Images:** JPG, PNG, GIF, WebP
- **Documents:** PDF, TXT, Word (.docx), Excel (.xlsx)
- **Code:** All plain-text formats (.py, .js, .java, etc.)
- **Other:** ZIP, video (partial support), audio

### Q10: What should I do if an agent fails to connect?
**A:**
1. Check your network connection (remote agent) or service status (Ollama)
2. Verify the endpoint URL, pairing code, or public-key whitelist (ACP v2.1 has **no shared Token**)
3. Tap **"Test Connection"** to diagnose the issue
4. Check **Settings → System Log / Inference Log**

---

## Quick Reference

### Keyboard Shortcuts (Desktop)
| Shortcut | Action |
|----------|--------|
| `Ctrl + Enter` / `Cmd + Enter` | Send message |
| `Ctrl + N` / `Cmd + N` | New conversation |
| `Ctrl + F` / `Cmd + F` | Search messages |
| `Ctrl + ,` / `Cmd + ,` | Open settings |
| `Esc` | Close dialog |

### UI Icon Reference
| Icon | Meaning |
|------|---------|
| 📷 | Upload image |
| 📎 | Attach file |
| 🎤 | Record voice |
| 😊 | Emoji picker |
| ⚙️ | Settings |
| 📋 | Chat history |
| 👥 | Group chat |

### Message Status Indicators
| Status | Meaning |
|--------|---------|
| ✓ | Message sent |
| ✓✓ | Message delivered |
| ⏳ | Waiting for reply |
| ⚠️ | Send failed |
| 🔒 | Encrypted message |

### Agent Connection Status
| Status | Icon | Meaning |
|--------|------|---------|
| Online | 🟢 | Agent is available |
| Offline | ⚪ | Agent is unavailable |
| Connecting | 🟡 | Establishing connection |
| Error | 🔴 | Connection error |

---

## Getting Help

If you run into any issues:
1. Check the FAQ section in this guide
2. Browse the in-app help documentation
3. Review the app logs (**Settings** → **About** → **View Logs**)
4. Submit a bug report (**Settings** → **About** → **Feedback**)

---

**Version:** Shepaw 1.0.0+1
**Last Updated:** March 21, 2026
**Language:** English

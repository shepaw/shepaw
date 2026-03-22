# Shepaw User Guide

> She can be your AI companion, or your most loyal confidante. The longer you spend together, the better she understands you — and the more you can trust her.
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
   - Go to the home screen and tap **"Add Agent"**
   - Choose between a **Local LLM Agent** or a **Remote Agent** (see below)

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
- **Ollama** — Locally deployed models (no network required)
- Any other provider with an OpenAI-compatible API

**Setup Steps:**
1. Tap **"+ Add Agent"** → **"Local LLM Agent"**
2. Enter an agent name (e.g., "ChatGPT")
3. Select the LLM provider
4. Enter your API key (or Ollama server URL)
5. Choose a model and configure parameters (temperature, max tokens, etc.)
6. Tap **"Save"**

#### 1.2 Remote Agent (via ACP Protocol)
A remote agent runs on a remote server and communicates with your device via the ACP protocol.

**Setup Steps:**
1. Tap **"+ Add Agent"** → **"Remote Agent"**
2. Enter the connection details:
   - **Agent ID** — Unique identifier
   - **Server URL** — Agent server address (e.g., `ws://192.168.1.100:8080`)
   - **Token** — Authentication token provided by the server
3. Tap **"Test Connection"** to verify
4. Tap **"Save"**

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

#### 3.2 Three Orchestration Modes

**Mode 1: Standard (Round-Robin)**
- The Admin Agent coordinates multiple member agents to take turns in the discussion
- Best for tasks that benefit from multiple perspectives
- Maximum rounds is configurable (default: 50)

**Mode 2: Planning Mode**
- The Admin generates a structured JSON execution plan
- You review, edit, or skip individual tasks in the UI
- Execution begins after your approval
- Best for automated workflows that still require human oversight

**Mode 3: Flow Mode**
- The Admin generates a multi-stage execution plan (Stage 1 → Stage 2 → ...)
- The system automatically drives each stage in sequence
- You can pause, resume, skip a stage, or abort at any time
- Best for fully automated, complex multi-step workflows

#### 3.3 Sending Messages in a Group
1. Open a group chat
2. Type your message in the input box
3. Use `@agentname` to direct a message to a specific agent
4. Tap Send

#### 3.4 Managing Execution Plans (Planning / Flow Mode)
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
1. Go to **Settings** → **Multimodal Config**
2. Assign an agent for each content type:
   - **Text** — e.g., GPT-4
   - **Images** — e.g., GPT-4 Vision or Claude Vision
   - **Audio** — a supported speech model
   - **Video** — a supported multimodal model
3. When you send a message containing one of these types, the system routes it automatically

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
1. Open Agent Details → **"Skill Packages"** tab
2. Tap **"Import Skill Package"**
3. Choose a source:
   - **Local File** — Upload a ZIP file from your device
   - **URL** — Enter a remote skill package URL
4. Tap **"Import"**
5. The agent automatically gains the new skills after import

---

### 3. Permission Management & Audit

Shepaw applies permission controls to all sensitive operations.

#### 3.1 Permission Levels
- **SAFE** — Low-risk operations, executed automatically
- **WARNING** — Operations requiring user confirmation
- **DANGEROUS** — High-risk operations requiring explicit approval

#### 3.2 Viewing Permission History
1. Go to **Settings** → **Permissions & Audit** → **Permission History**
2. Browse all operation requests made by agents
3. Each record shows:
   - Operation description
   - Agent name
   - Timestamp
   - Approval status (Approved / Denied)

#### 3.3 Inference Logs
1. Go to **Settings** → **Inference Log Audit**
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

#### 3.1 Exporting Data
1. Go to **Settings** → **Data Management** → **Export Data**
2. Choose a format:
   - **JSON** — Full backup of all data
   - **CSV** — Chat history only
3. Tap **"Export"**
4. Choose a save location

#### 3.2 Importing a Backup
1. Go to **Settings** → **Data Management** → **Import Data**
2. Select your backup file (JSON format)
3. Tap **"Import"**
4. The app will restore all data from the backup

---

### 4. Deleting Data

#### 4.1 Delete a Single Conversation
- Long-press a conversation in the list
- Select **"Delete"**

#### 4.2 Delete All Data
1. Go to **Settings** → **Data Management** → **Clear All Data**
2. Enter your confirmation password
3. Tap **"Confirm Delete"**
4. **Warning: This action is irreversible**

---

## FAQ

### Q1: How do I connect to a local Ollama model?
**A:**
1. Install Ollama on your computer (ollama.ai)
2. Pull a model: `ollama pull llama2`
3. In Shepaw, add a Local LLM Agent and choose Ollama
4. Enter the server URL: `http://localhost:11434`
5. Tap **"Test Connection"** to verify

### Q2: What is the difference between Planning Mode and Flow Mode?
**A:**
- **Planning Mode** — The AI generates a plan; you review and modify each task in the UI before execution begins
- **Flow Mode** — The AI generates a multi-stage plan; the system executes all stages automatically while you can pause or abort at any time

Use Planning Mode when you want fine-grained human control. Use Flow Mode for fully automated end-to-end workflows.

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
- Generating execution plans (Planning/Flow Mode)
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
2. Verify that the Server URL and Token are correct
3. Tap **"Test Connection"** to diagnose the issue
4. Review the app logs for detailed error information

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

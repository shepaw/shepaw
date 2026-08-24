# ShePaw

> **Language / 语言:** **English** | [中文](README_CN.md)

> ShePaw — Local-first, Multi-protocol, Cross-platform, AI-agent-cooperation

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Windows-lightgrey)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

<p align="center">
  <img src="assets/images/shepaw_icon.png" width="120" alt="ShePaw Logo" />
</p>

> She can be your AI spirit pet, or your most loyal confidante. The longer you spend together, the better she understands you — and the more you can trust her.
> Everyone deserves multiple AI assistants, and one ShePaw.

ShePaw is a cross-platform hub for interacting and collaborating with your AI assistants — but **she** is the one who helps you navigate the world of AI.

Designed with a local-first philosophy: all your data stays on your device. ShePaw supports multiple Agent communication protocols and delivers a rich chat and automation experience.

**[用户使用指南 (中文)](docs/USER_GUIDE.md)** · **[User Guide (English)](docs/USER_GUIDE_EN.md)**

---

## Highlights

### Agent Management & Communication
- **She — the built-in guardian agent (spirit pet)** — a persona that lives and grows with you: soul, resume (bio), long-term memory, cognition, and a user profile it actively learns
- **ACP Protocol** (Agent Communication Protocol) — Real-time bidirectional WebSocket communication based on JSON-RPC 2.0
- **Local LLM Agents** — direct integration with 11 major LLM services: OpenAI, Claude, Gemini, Grok, DeepSeek, Qwen, GLM, Kimi, Hunyuan, OpenRouter, Ollama, plus any OpenAI-compatible API
- **Remote / Peer Agents** — ACP agents on other devices, plus agents exposed from paired devices (agent-over-Peer)
- **ShePaw CLI for agents** — a built-in `shepaw <namespace> <command>` tool tree (context / chat / tools / skills / os / workflow / store / meta …) that lets She and other agents read and modify local data through LLM function calling
- Bidirectional communication: user-initiated chat & agent-initiated messages (with authorization)
- Real-time connection monitoring, health checks, and token authentication

### Smart Chat
- Rich message bubbles (text, images, files, voice, Markdown, code highlighting)
- Multimodal support: text, images, audio, video, and more
- Interactive components: forms, single/multiple choice, action confirmation buttons
- Message replies, context menus, session fork (long-press a session to fork it), full-text search
- Live typing indicators and streaming responses
- Inbox / mailbox: out-of-band agent replies are sealed and resumed into the conversation

### Collaboration & Automation
- **Direct Message / Group Channel** — multiple agents working together
- **Three group orchestration modes:**
  - **Standard** — Admin coordinates agents in round-robin discussion (up to 50 rounds)
  - **Planning Mode** — Agent generates a JSON execution plan; you review and approve each task before it runs
  - **Flow Mode** — Agent produces a multi-stage workflow; the system drives execution automatically with pause / resume / skip / abort controls
- **Dispatch** — admin clarifies your requirements first, then dispatches tasks to capable members via `@` mentions; structured `json` dispatch blocks are also supported
- **Group memory & workspace** — shared memory distillation, member artifacts persisted to the group workspace, group context injected into every member turn
- **Group permission model** — the admin (or She) holds full group-management permissions; regular members can self-edit their own bio / role only
- **Multimodal Routing** — per-modality model assignment (text / image / audio / video / image-gen / video-gen), including custom intent-based modalities
- **OS Tools** — file operations, process execution, system info queries (with sandbox policy)
- **Skill Packages** — import custom skill bundles from a local ZIP or URL
- **Scheduled Tasks** — cron-style automation that runs agent or group tasks on a schedule
- **Web tools** — built-in web search (Brave / Tavily) and web fetch services for agents

### Storage Bag (储物袋) & Local-first Data
- **Store protocol** (`store://`) — a structured, device-scoped storage space with spaces: `workspaces` / `runtime` / `files` / `public` / `backups` / `cognition` (plus legacy `artifacts` / `attachments` / `memory`)
- **Storage bag UI** — browse, search, and manage files; friendly recent-tab; internal/system files can be hidden
- **Snapshots** — scheduled encrypted snapshots with GFS retention and recycle bin / versioning
- **P2P mirror sync** — offline-friendly sync engine with change cursors and batched atomic uploads; cross-device mirroring
- **Folder binding** — bind a local folder on desktop and sync it via FS watcher (with periodic fallback)
- **Agent workspaces** — each agent/group gets a workspace in the pouch; agent resumes (`resume.md`) live there and are readable/writable via `shepaw store`
- **WebDAV export & backups** — export your store to WebDAV, restore, and manage snapshots
- **NexusPouch / Storage Node** — optional headless Go store master, paired by QR and discovered over mDNS, serving `store.*` frames over Noise-encrypted WebSocket

### P2P Devices & She Network
- **Device pairing** — pair devices via QR code, deep link, or scanner; handshake secured with the **Noise Protocol** (X25519 + ChaCha20-Poly1305)
- **Agent-over-Peer & store sync** — expose local agents to paired devices and sync storage spaces between devices
- **Channel tunnel** — maintain a tunnel to a channel server so remote peers can reach you across networks
- **She Network** — presence broadcasting and memory exchange between She instances across your devices

### Security & Privacy
- Local-first storage (SQLite); sensitive credentials use platform Secure Storage — no mandatory cloud backend
- Password + biometric lock (Face ID / Touch ID / fingerprint)
- Encrypted API key storage, ACP permission approval for agent-initiated actions, and risk-gated OS tools (safe / low-risk / high-risk with confirmation dialogs + sandbox policy)
- E2E-encrypted peer channels (Noise Protocol); sandboxed OS tool execution
- Encrypted vault backup & restore (password-protected snapshots re-encrypted on password change)
- Inference log audit (token usage, response time, error records)

### Cross-platform
- iOS / Android / macOS / Windows
- Desktop multi-window support, adaptive layout (split panel on desktop / single screen on mobile)
- Internationalization (Chinese / English)

---

## Quick Start

### Requirements

- Flutter 3.x & Dart SDK 3.0+
- Xcode (iOS / macOS) or Android Studio (Android)

### Install & Run

```bash
# Clone the repository
git clone https://github.com/shepaw/shepaw.git
cd shepaw

# Install dependencies
flutter pub get

# Run on your target platform
flutter run                # default device
flutter run -d macos       # macOS
flutter run -d android     # Android
```

### Build for Release

```bash
flutter build apk --release    # Android
flutter build ios --release    # iOS  (requires macOS + Xcode)
flutter build macos --release  # macOS
```

Windows builds use the dedicated script (see [BUILD_GUIDE.md](BUILD_GUIDE.md)):

```powershell
.\build_windows.ps1
```

For detailed build instructions, see [BUILD_GUIDE.md](BUILD_GUIDE.md).

---

## Supported LLM Providers

| Type | Providers |
|------|-----------|
| Cloud | OpenAI (GPT-4 / GPT-4o), Anthropic Claude, Google Gemini, Grok, DeepSeek, Qwen (Alibaba), GLM (Zhipu), Kimi (Moonshot), Hunyuan (Tencent), OpenRouter |
| Local | Ollama (llama3, llava, and any locally deployed model) |
| Custom | Any service with an OpenAI-compatible API |

---

## Project Structure

```
shepaw/
├── lib/
│   ├── main.dart                        # App entry point (main window + sub-window detection)
│   ├── sub_window_app.dart              # Desktop multi-window manager
│   ├── app_bootstrap.dart               # Startup orchestration
│   ├── service_locator.dart             # get_it composition root
│   ├── models/                          # Data models (38 files)
│   │   ├── agent.dart                   # Agent model
│   │   ├── remote_agent.dart            # Remote Agent (ACP)
│   │   ├── channel.dart                 # Channel / conversation model
│   │   ├── message.dart                 # Message model
│   │   ├── model_routing_config.dart    # Multimodal routing config
│   │   ├── workflow_models.dart         # Flow workflow models
│   │   └── ...
│   ├── screens/                         # UI screens (57 files)
│   │   ├── adaptive_home_screen.dart    # Adaptive home (mobile / desktop)
│   │   ├── chat_screen.dart             # Chat interface
│   │   ├── storage_space_screen.dart    # Storage bag overview (储物袋)
│   │   ├── storage_browser_screen.dart  # Storage bag file browser
│   │   ├── remote_agent_detail_screen.dart  # Agent detail & config
│   │   └── ...
│   ├── widgets/                         # UI components (73 files)
│   │   ├── chat/                        # Chat widgets (bubbles, panels, menus)
│   │   ├── workflow/                    # Flow task board widgets
│   │   ├── storage/                     # Storage bag widgets
│   │   ├── approval/                    # Pending-approval widgets
│   │   └── ...
│   ├── services/                        # Core services (78+ files)
│   │   ├── chat_service.dart            # Chat service (message hub)
│   │   ├── local_database_service.dart  # Database service (SQLite)
│   │   ├── acp_agent_connection.dart    # ACP connection manager (WebSocket)
│   │   ├── local_llm_agent_service.dart # Local LLM agent service
│   │   ├── group/                       # Group orchestration engine
│   │   ├── workflow/                    # Flow workflow engine
│   │   ├── session/                     # Session history & compaction
│   │   ├── mailbox/                     # Inbox & mailbox reply router
│   │   ├── database/                    # Domain DAO extensions
│   │   ├── model_registry.dart          # AI model registry
│   │   ├── skill_registry.dart          # Skill registry
│   │   ├── cli_tool_registry.dart       # External CLI tool registry
│   │   └── ...
│   ├── storage/                         # Storage bag / pouch engine
│   │   ├── store_service.dart           # Store protocol service
│   │   ├── sync_engine.dart             # P2P sync engine
│   │   ├── snapshot_service.dart        # Encrypted snapshots
│   │   ├── folder_binding_service.dart  # Folder binding (FS watcher)
│   │   ├── webdav_export_service.dart   # WebDAV export
│   │   └── ...
│   ├── peer/                            # Device pairing & P2P (Noise E2E)
│   │   ├── services/                    # Pairing / connection / agent host
│   │   ├── screens/                     # Pairing UI screens
│   │   └── models/                      # Paired peer models
│   ├── she_network/                     # She network (presence + memory exchange)
│   ├── task/                            # Scheduled tasks (cron)
│   ├── clis/                            # ShePaw CLI for agents
│   │   └── shepaw/                      # shepaw <namespace> <command> tree
│   ├── controllers/                     # Chat / conversation coordinators
│   ├── providers/                       # Light global prefs (Provider)
│   ├── config/                          # App / env / product feature config
│   ├── theme/                           # App theme
│   ├── l10n/                            # Internationalization (EN / ZH)
│   └── utils/                           # Utilities
├── test/                                # Tests (179 files)
├── docs/                                # Documentation
│   ├── USER_GUIDE.md                    # User guide (Chinese)
│   ├── USER_GUIDE_EN.md                 # User guide (English)
│   ├── agent_integration_guide.md       # ACP protocol integration guide
│   ├── remote_llm_agent_integration.md  # Remote LLM Agent integration guide (Chinese)
│   ├── remote_llm_agent_integration_en.md  # Remote LLM Agent integration guide (English)
│   ├── storage_protocol_spec.md         # Store protocol specification
│   ├── tool_model_architecture.md       # Tool model architecture
│   └── gorup_chat_flow.md               # Group channel flow documentation
├── storage-node/                        # Headless store master (Go, optional)
├── cli-tools/                           # External CLI tool packages (e.g. Brave search)
├── android/ ios/ macos/ windows/        # Platform entry points
├── assets/                              # Static assets
├── pubspec.yaml
├── BUILD_GUIDE.md                       # Multi-platform build guide
└── DEVELOPMENT.md                       # Development workflow
```

---

## Development

For code style and workflow guidelines, see [DEVELOPMENT.md](DEVELOPMENT.md).

```bash
# Analyze code
flutter analyze

# Format code
dart format .

# Run unit tests (CI excludes plugin-integration tags)
flutter test --exclude-tags=needs-plugins

# Run specific tests
flutter test test/models/
flutter test test/integration/
```

---

## Tech Stack

| Category | Technology |
|----------|------------|
| Framework | Flutter 3.x / Dart 3.0+ |
| DI / Services | `get_it` service locator + Stream / ChangeNotifier |
| UI local state | `StatefulWidget` / `setState` |
| Light global prefs | Provider + ChangeNotifier (`lib/providers/`) |
| Database | SQLite (`sqflite`) with domain DAO extensions |
| Vector / Embedding | `veda` vector DB, `tflite_flutter` |
| Secure secrets | `flutter_secure_storage` (Keychain / Keystore) via `SecureKeyManager` |
| Local prefs | SharedPreferences |
| Networking | Dio, HTTP, `web_socket_channel` (ACP / Peer / Channel tunnel), `multicast_dns` (mDNS discovery) |
| E2E encryption | Noise Protocol (`cryptography`) — X25519 + ChaCha20-Poly1305 |
| Security | crypto, encrypt, local_auth, OS-tool confirmation gates + sandbox policy |
| UI | Material Design 3, flutter_markdown, flutter_highlight, flutter_svg, cached_network_image |
| Multimedia | image_picker, record, audioplayers, file_picker, open_file |
| Desktop | desktop_multi_window, pasteboard, watcher (folder binding) |
| Notifications | flutter_local_notifications, local_notifier (Windows) |
| Permissions / background | permission_handler, flutter_foreground_task, workmanager, wakelock_plus |
| QR pairing | mobile_scanner, qr_flutter |
| Tasks | `cron`-style scheduling (`task/`) |

---

## Documentation

| Document | Description |
|----------|-------------|
| [User Guide (English)](docs/USER_GUIDE_EN.md) | Complete end-user feature guide |
| [用户使用指南（中文）](docs/USER_GUIDE.md) | 面向最终用户的完整功能说明 |
| [Build Guide](BUILD_GUIDE.md) | Platform-specific build instructions |
| [Development Guide](DEVELOPMENT.md) | Code standards and workflow |
| [Store Release Checklist](docs/STORE_RELEASE_CHECKLIST.md) | PrivacyInfo, deep links, store assets |
| [Agent Integration Guide](docs/agent_integration_guide.md) | ACP protocol integration docs (SDK reference) |
| [Remote LLM Agent Integration](docs/remote_llm_agent_integration_en.md) | Complete guide for third-party Remote Agent integration (English) |
| [Remote LLM Agent 接入指南](docs/remote_llm_agent_integration.md) | 第三方 Remote Agent 完整接入文档（中文） |
| [Store Protocol Specification](docs/storage_protocol_spec.md) | `store://` protocol spec (Dart + Go authority) |
| [Tool Model Architecture](docs/tool_model_architecture.md) | Tool model system overview |
| [Group Chat Flow](docs/gorup_chat_flow.md) | Group channel workflow documentation |

---

## License

[MIT License](LICENSE)

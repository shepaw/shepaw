# ShePaw

> **Language / 语言:** [中文](README_CN.md) | **English**
>
> ℹ️ This file is kept for compatibility. The canonical English README is now [README.md](README.md).

> ShePaw — Local-first, Multi-protocol, Cross-platform, AI-agent-cooperation

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Windows%20%7C%20Web-lightgrey)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

<p align="center">
  <img src="assets/images/shepaw_icon.png" width="120" alt="ShePaw Logo" />
</p>

> She can be your AI companion, or your most loyal confidante. The longer you spend together, the better she understands you — and the more you can trust her.
> Everyone deserves multiple AI assistants, and one ShePaw.

ShePaw is a cross-platform hub for interacting and collaborating with your AI assistants — but **she** is the one who helps you navigate the world of AI.

Designed with a local-first philosophy: all your data stays on your device. ShePaw supports multiple Agent communication protocols and delivers a rich chat and automation experience.

**[用户使用指南 (中文)](docs/USER_GUIDE.md)** · **[User Guide (English)](docs/USER_GUIDE_EN.md)**

---

## Highlights

### Agent Management & Communication
- **ACP Protocol** (Agent Communication Protocol) — Real-time bidirectional WebSocket communication based on JSON-RPC 2.0
- **Local LLM Agents** — Direct integration with 9+ major LLM services: OpenAI, Claude, Gemini, DeepSeek, Qwen, GLM, Kimi, Ollama, and more
- Bidirectional communication: user-initiated chat & agent-initiated messages (with authorization)
- Real-time connection monitoring, health checks, and token authentication

### Smart Chat
- Rich message bubbles (text, images, files, voice, Markdown, code highlighting)
- Multimodal support: text, images, audio, video, and more
- Interactive components: forms, single/multiple choice, action confirmation buttons
- Message replies, context menus, full-text search
- Live typing indicators and streaming responses

### Collaboration & Automation
- **Direct Message / Group Channel** — multiple agents working together
- **Three group orchestration modes:**
  - **Standard** — Admin coordinates agents in round-robin discussion (up to 50 rounds)
  - **Planning Mode** — Agent generates a JSON execution plan; you review and approve each task before it runs
  - **Flow Mode** — Agent produces a multi-stage workflow; the system drives execution automatically with pause / resume / skip / abort controls
- **Multimodal Routing** — automatically assigns the best model for text, images, audio, and video
- **OS Tools** — file operations, process execution, system info queries
- **Skill Packages** — import custom skill bundles from a local ZIP or URL

### Security & Privacy
- All data stored locally (SQLite + Hive) — no backend server required
- Password + biometric lock (Face ID / Touch ID / fingerprint)
- Encrypted API key storage, three-tier permission system (SAFE / WARNING / DANGEROUS)
- Inference log audit (token usage, response time, error records)

### Cross-platform
- iOS / Android / macOS / Windows / Web
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
flutter run -d chrome      # Web
```

### Build for Release

```bash
flutter build apk --release    # Android
flutter build ios --release    # iOS
flutter build macos --release  # macOS
```

For detailed build instructions, see [BUILD_GUIDE.md](BUILD_GUIDE.md).

---

## Supported LLM Providers

| Type | Providers |
|------|-----------|
| Cloud | OpenAI (GPT-4 / GPT-4o), Anthropic Claude, Google Gemini, DeepSeek, Qwen, GLM (Zhipu), Kimi (Moonshot), Grok, Hunyuan (Tencent) |
| Local | Ollama (llama3, llava, and any locally deployed model) |
| Custom | Any service with an OpenAI-compatible API |

---

## Project Structure

```
shepaw/
├── lib/
│   ├── main.dart                        # App entry point
│   ├── sub_window_app.dart              # Desktop multi-window manager
│   ├── models/                          # Data models (19 files)
│   │   ├── agent.dart                   # Agent model
│   │   ├── remote_agent.dart            # Remote Agent (ACP)
│   │   ├── channel.dart                 # Channel / conversation model
│   │   ├── message.dart                 # Message model
│   │   └── ...
│   ├── screens/                         # UI screens (37+)
│   │   ├── home_screen.dart             # Home (mobile)
│   │   ├── desktop_home_screen.dart     # Home (desktop)
│   │   ├── chat_screen.dart             # Chat interface
│   │   ├── add_remote_agent_screen.dart # Add remote agent
│   │   ├── remote_agent_detail_screen.dart  # Agent detail & config
│   │   └── ...
│   ├── widgets/                         # UI components (24 files)
│   │   ├── chat/                        # Chat-related widgets
│   │   ├── message_bubble.dart          # Message bubble
│   │   ├── plan_approval_card.dart      # Planning task approval card
│   │   ├── task_board_widget.dart       # Flow task board
│   │   └── ...
│   ├── services/                        # Core services (50+ files)
│   │   ├── chat_service.dart            # Chat service (message hub)
│   │   ├── local_database_service.dart  # Database service (SQLite)
│   │   ├── acp_agent_connection.dart    # ACP connection manager (WebSocket)
│   │   ├── local_llm_agent_service.dart # Local LLM agent service
│   │   ├── model_registry.dart          # AI model registry
│   │   ├── skill_registry.dart          # Skill registry
│   │   ├── os_tool_registry.dart        # OS tool registry
│   │   ├── permission_service.dart      # Permission management
│   │   └── ...
│   ├── group/                           # Group orchestration engine (7 files)
│   │   ├── group_orchestration_service.dart  # Orchestration core
│   │   ├── planning_mode_handler.dart   # Planning mode handler
│   │   ├── flow_mode_handler.dart       # Flow mode handler
│   │   └── ...
│   ├── providers/                       # State management (Provider)
│   ├── l10n/                            # Internationalization (EN / ZH)
│   └── utils/                           # Utilities
├── test/                                # Tests (18 files)
├── docs/                                # Documentation
│   ├── USER_GUIDE.md                    # User guide (Chinese)
│   ├── USER_GUIDE_EN.md                 # User guide (English)
│   ├── agent_integration_guide.md       # ACP protocol integration guide
│   ├── remote_llm_agent_integration.md     # Remote LLM Agent integration guide (Chinese)
│   ├── remote_llm_agent_integration_en.md  # Remote LLM Agent integration guide (English)
│   ├── tool_model_architecture.md       # Tool model architecture
│   └── gorup_chat_flow.md               # Group channel flow documentation
├── scripts/
│   └── mock_agents/                     # Mock agent test environment (4 agents)
├── android/ ios/ macos/ windows/ web/   # Platform entry points
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

# Run all tests
flutter test

# Run specific tests
flutter test test/models/
flutter test test/integration/
```

---

## Tech Stack

| Category | Technology |
|----------|------------|
| Framework | Flutter 3.x / Dart 3.0+ |
| State Management | Provider, Get |
| Database | SQLite (sqflite) |
| Local Storage | Hive, SharedPreferences, Flutter Secure Storage |
| Networking | Dio, HTTP, WebSocket |
| Security | crypto, encrypt, flutter_secure_storage, local_auth |
| UI | Material Design 3, flutter_markdown, flutter_highlight |
| Multimedia | image_picker, record, audioplayers, file_picker |
| Desktop | desktop_multi_window, pasteboard |
| Notifications | flutter_local_notifications |
| Permissions | permission_handler, flutter_foreground_task |

---

## Documentation

| Document | Description |
|----------|-------------|
| [User Guide (English)](docs/USER_GUIDE_EN.md) | Complete end-user feature guide |
| [用户使用指南（中文）](docs/USER_GUIDE.md) | 面向最终用户的完整功能说明 |
| [Build Guide](BUILD_GUIDE.md) | Platform-specific build instructions |
| [Development Guide](DEVELOPMENT.md) | Code standards and workflow |
| [Agent Integration Guide](docs/agent_integration_guide.md) | ACP protocol integration docs (SDK reference) |
| [Remote LLM Agent Integration](docs/remote_llm_agent_integration_en.md) | Complete guide for third-party Remote Agent integration (English) |
| [Remote LLM Agent 接入指南](docs/remote_llm_agent_integration.md) | 第三方 Remote Agent 完整接入文档（中文） |
| [Tool Model Architecture](docs/tool_model_architecture.md) | Tool model system overview |
| [Group Chat Flow](docs/gorup_chat_flow.md) | Group channel workflow documentation |

---

## License

[MIT License](LICENSE)

# ShePaw

> **Language / 语言:** [English](README.md) | **中文**

> ShePaw — Local-first, Multi-protocol, Cross-platform, AI-agent-cooperation

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Windows%20%7C%20Web-lightgrey)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

<p align="center">
  <img src="assets/images/shepaw_icon.png" width="120" alt="Shepaw Logo" />
</p>

> "她"可以是你的 AI 伴侣，也可以是你最忠实的闺蜜。相处越久，会越懂你，更值得被信任。
> 每个人都应该有多个 AI 助手，和一个"她"。

Shepaw是一个跨平台的 AI助理们交互协作的平台，但"她"可以帮你搞定属于AI的世界。

以本地优先的理念设计，所有数据存储在用户设备上，支持多种 Agent 通信协议，提供丰富的聊天与自动化协作体验。

**[用户使用指南 (中文)](docs/USER_GUIDE.md)** · **[User Guide (English)](docs/USER_GUIDE_EN.md)**

---

## 功能亮点

### Agent 管理与通信
- **ACP 协议**（Agent Communication Protocol）— 基于 JSON-RPC 2.0 的 WebSocket 双向实时通信
- **本地 LLM Agent** — 直接集成 OpenAI、Claude、Gemini、DeepSeek、Qwen、GLM、Kimi、Ollama 等 9+ 主流 LLM 服务
- 双向通信：用户主动对话 & Agent 主动发起对话（需授权）
- 连接状态实时监控、健康检查、Token 认证

### 智能聊天
- 富文本消息气泡（文本、图片、文件、语音、Markdown、代码高亮）
- 多模态支持：文本、图片、音频、视频等多种媒体类型
- 交互式组件：表单、单选 / 多选、操作确认按钮
- 消息回复、上下文菜单、全文搜索
- 实时打字状态指示、流式响应

### 协作与自动化
- **Direct Message / Group Channel** — 支持多 Agent 协同工作
- **三种群组编排模式：**
  - **标准模式** — Admin 协调多 Agent 轮流参与讨论（最多 50 轮）
  - **Planning Mode** — Agent 生成 JSON 执行计划，用户审核后执行，支持逐任务审批与修改
  - **Flow Mode** — Agent 生成分阶段工作流，系统自动驱动执行，支持暂停 / 恢复 / 跳步 / 中止
- **多模态路由** — 为文本、图片、音频、视频自动分配最适合的模型
- **系统工具（OS Tools）** — 文件操作、进程执行、系统信息查询
- **技能包（Skills）** — 支持从本地 ZIP 或 URL 导入自定义技能扩展

### 安全与隐私
- 全部数据本地存储（SQLite + Hive），无需后端服务器
- 密码 + 生物识别（Face ID / Touch ID / 指纹）锁屏保护
- API Key 加密存储、三级权限管理（SAFE / WARNING / DANGEROUS）
- 推理日志审计（Token 消耗、响应时间、错误记录）

### 跨平台支持
- iOS / Android / macOS / Windows / Web
- 桌面端多窗口支持、自适应布局（Desktop 分割面板 / Mobile 单屏）
- 国际化（中文 / English）

---

## 快速开始

### 环境要求

- Flutter 3.x & Dart SDK 3.0+
- Xcode（iOS / macOS）或 Android Studio（Android）

### 安装与运行

```bash
# 克隆项目
git clone https://github.com/shepaw/shepaw.git
cd shepaw

# 安装依赖
flutter pub get

# 运行（选择目标平台）
flutter run                # 默认设备
flutter run -d macos       # macOS
flutter run -d chrome      # Web
```

### 构建发布包

```bash
flutter build apk --release    # Android
flutter build ios --release    # iOS
flutter build macos --release  # macOS
```

详细构建说明请参考 [BUILD_GUIDE.md](BUILD_GUIDE.md)。

---

## 支持的 LLM 提供商

| 类型 | 提供商 |
|------|--------|
| 云端 | OpenAI (GPT-4 / GPT-4o)、Anthropic Claude、Google Gemini、DeepSeek、Qwen（通义千问）、GLM（智谱）、Kimi（月之暗面）、Grok、Hunyuan（腾讯混元） |
| 本地 | Ollama（llama3、llava 等任意本地模型） |
| 自定义 | 任何兼容 OpenAI API 的服务 |

---

## 项目结构

```
shepaw/
├── lib/
│   ├── main.dart                        # 应用入口
│   ├── sub_window_app.dart              # 桌面端多窗口管理
│   ├── models/                          # 数据模型（19 个）
│   │   ├── agent.dart                   # Agent 模型
│   │   ├── remote_agent.dart            # Remote Agent (ACP)
│   │   ├── channel.dart                 # Channel / 会话模型
│   │   ├── message.dart                 # 消息模型
│   │   └── ...
│   ├── screens/                         # 页面（37+ 屏幕）
│   │   ├── home_screen.dart             # 主页（移动端）
│   │   ├── desktop_home_screen.dart     # 主页（桌面端）
│   │   ├── chat_screen.dart             # 聊天界面
│   │   ├── add_remote_agent_screen.dart # 添加远端 Agent
│   │   ├── remote_agent_detail_screen.dart  # Agent 详情与配置
│   │   └── ...
│   ├── widgets/                         # UI 组件（24 个）
│   │   ├── chat/                        # 聊天相关组件
│   │   ├── message_bubble.dart          # 消息气泡
│   │   ├── plan_approval_card.dart      # Planning 任务审批卡片
│   │   ├── task_board_widget.dart       # Flow 任务看板
│   │   └── ...
│   ├── services/                        # 核心服务（50+ 文件）
│   │   ├── chat_service.dart            # 聊天服务（消息处理中心）
│   │   ├── local_database_service.dart  # 数据库服务（SQLite）
│   │   ├── acp_agent_connection.dart    # ACP 连接管理（WebSocket）
│   │   ├── local_llm_agent_service.dart # 本地 LLM Agent 服务
│   │   ├── model_registry.dart          # AI 模型注册表
│   │   ├── skill_registry.dart          # 技能注册表
│   │   ├── os_tool_registry.dart        # OS 工具注册表
│   │   ├── permission_service.dart      # 权限管理
│   │   └── ...
│   ├── group/                           # 群组编排引擎（7 个文件）
│   │   ├── group_orchestration_service.dart  # 编排核心
│   │   ├── planning_mode_handler.dart   # Planning 模式处理器
│   │   ├── flow_mode_handler.dart       # Flow 模式处理器
│   │   └── ...
│   ├── providers/                       # 状态管理（Provider）
│   ├── l10n/                            # 国际化（EN / ZH）
│   └── utils/                           # 工具类
├── test/                                # 测试（18 个文件）
├── docs/                                # 文档
│   ├── USER_GUIDE.md                    # 用户使用指南（中文）
│   ├── USER_GUIDE_EN.md                 # User Guide (English)
│   ├── agent_integration_guide.md       # ACP 协议集成指南
│   ├── remote_llm_agent_integration.md     # Remote LLM Agent 接入指南（中文）
│   ├── remote_llm_agent_integration_en.md  # Remote LLM Agent Integration Guide (EN)
│   ├── tool_model_architecture.md       # 工具模型系统文档
│   └── gorup_chat_flow.md               # Group Channel 流程文档
├── scripts/
│   └── mock_agents/                     # Mock Agent 测试环境（4 个测试 Agent）
├── android/ ios/ macos/ windows/ web/   # 各平台入口
├── assets/                              # 静态资源
├── pubspec.yaml
├── BUILD_GUIDE.md                       # 多平台构建指南
└── DEVELOPMENT.md                       # 开发工作流程
```

---

## 开发

代码规范和工作流程请参考 [DEVELOPMENT.md](DEVELOPMENT.md)。

```bash
# 代码分析
flutter analyze

# 格式化
dart format .

# 运行测试
flutter test

# 运行特定测试
flutter test test/models/
flutter test test/integration/
```

---

## 技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Flutter 3.x / Dart 3.0+ |
| 状态管理 | Provider, Get |
| 数据库 | SQLite (sqflite) |
| 本地存储 | Hive, SharedPreferences, Flutter Secure Storage |
| 网络 | Dio, HTTP, WebSocket |
| 安全 | crypto, encrypt, flutter_secure_storage, local_auth |
| UI | Material Design 3, flutter_markdown, flutter_highlight |
| 多媒体 | image_picker, record, audioplayers, file_picker |
| 桌面 | desktop_multi_window（多窗口）, pasteboard（剪贴板） |
| 通知 | flutter_local_notifications |
| 权限 | permission_handler, flutter_foreground_task |

---

## 文档

| 文档 | 说明 |
|------|------|
| [用户使用指南（中文）](docs/USER_GUIDE.md) | 面向最终用户的完整功能说明 |
| [User Guide (English)](docs/USER_GUIDE_EN.md) | End-user guide in English |
| [构建指南](BUILD_GUIDE.md) | 各平台详细构建说明 |
| [开发指南](DEVELOPMENT.md) | 代码规范和工作流程 |
| [Agent 接入指南](docs/agent_integration_guide.md) | ACP 协议集成文档（SDK 参考） |
| [Remote LLM Agent 接入指南](docs/remote_llm_agent_integration.md) | 第三方 Remote Agent 完整接入文档（中文） |
| [Remote LLM Agent Integration Guide](docs/remote_llm_agent_integration_en.md) | Third-party Remote Agent integration guide (English) |
| [工具模型架构](docs/tool_model_architecture.md) | 工具模型系统说明 |
| [群组聊天流程](docs/gorup_chat_flow.md) | Group Channel 流程文档 |

---

## 许可证

[MIT License](LICENSE)

# ShePaw

> **Language / 语言:** [English](README.md) | **中文**

> ShePaw — Local-first, Multi-protocol, Cross-platform, AI-agent-cooperation

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev/)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev/)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android%20%7C%20macOS%20%7C%20Windows-lightgrey)]()
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

<p align="center">
  <img src="assets/images/shepaw_icon.png" width="120" alt="Shepaw Logo" />
</p>

> "她"可以是你的 AI 灵宠。相处越久，会越懂你，更值得被信任。
> 每个人都应该有多个 AI 助手，和一个"她"。

Shepaw是一个跨平台的 AI助理们交互协作的平台，但"她"可以帮你搞定属于AI的世界。

以本地优先的理念设计，所有数据存储在用户设备上，支持多种 Agent 通信协议，提供丰富的聊天与自动化协作体验。

**[用户使用指南 (中文)](docs/USER_GUIDE.md)** · **[User Guide (English)](docs/USER_GUIDE_EN.md)**

---

## 功能亮点

### Agent 管理与通信
- **She —— 内置守护 Agent（灵宠）** —— 一个随你相处而成长的"她"：灵魂、简历（bio）、长期记忆、认知与用户画像，会主动了解你
- **ACP 协议**（Agent Communication Protocol）— 基于 JSON-RPC 2.0 的 WebSocket 双向实时通信
- **本地 LLM Agent** — 直接集成 11 家主流 LLM 服务：OpenAI、Claude、Gemini、Grok、DeepSeek、Qwen、GLM、Kimi、Hunyuan、OpenRouter、Ollama，以及任意兼容 OpenAI API 的服务
- **Remote / Peer Agent** — 其他设备上的 ACP Agent，以及配对设备共享出来的 Agent（agent-over-Peer）
- **ShePaw CLI（Agent 命令树）** — 内置 `shepaw <namespace> <command>` 工具树（context / chat / tools / skills / os / workflow / store / meta …），让 She 与其他 Agent 通过函数调用读写本地数据
- 双向通信：用户主动对话 & Agent 主动发起对话（需授权）
- 连接状态实时监控、健康检查、Token 认证

### 智能聊天
- 富文本消息气泡（文本、图片、文件、语音、Markdown、代码高亮）
- 多模态支持：文本、图片、音频、视频等多种媒体类型
- 交互式组件：表单、单选 / 多选、操作确认按钮
- 消息回复、上下文菜单、会话分叉（长按会话 Fork）、全文搜索
- 实时打字状态指示、流式响应
- 收件箱 / 邮箱：离线回复先封存，稍后恢复进会话

### 协作与自动化
- **Direct Message / Group Channel** — 支持多 Agent 协同工作
- **三种群组编排模式：**
  - **标准模式** — Admin 协调多 Agent 轮流参与讨论（最多 50 轮）
  - **Planning Mode** — Agent 生成 JSON 执行计划，用户审核后执行，支持逐任务审批与修改
  - **Flow Mode** — Agent 生成分阶段工作流，系统自动驱动执行，支持暂停 / 恢复 / 跳步 / 中止
- **任务派发（Dispatch）** — Admin 先澄清需求，再通过 `@` 提及把任务派发给合适的成员；也支持结构化 `json` 派发块
- **群记忆与工作空间** — 共享记忆蒸馏、成员产物落盘到群工作空间、群上下文注入每位成员的每一轮
- **群权限模型** — Admin（或 She）拥有完整群管理权限；普通成员只能自助编辑自己的 bio / 角色介绍
- **多模态路由** — 按模态分配模型（文本 / 图片 / 音频 / 视频 / 图片生成 / 视频生成），支持自定义意图路由
- **系统工具（OS Tools）** — 文件操作、进程执行、系统信息查询（含沙箱策略）
- **技能包（Skills）** — 支持从本地 ZIP 或 URL 导入自定义技能扩展
- **定时任务** — 类 cron 调度，可按计划自动执行 Agent 或群组任务
- **Web 工具** — 内置 Web 搜索（Brave / Tavily）与网页抓取服务，供 Agent 使用

### 储物袋与本地优先数据
- **Store 协议**（`store://`）— 结构化、按设备分区的存储空间：`workspaces` / `runtime` / `files` / `public` / `backups` / `cognition`（以及遗留的 `artifacts` / `attachments` / `memory`）
- **储物袋 UI** — 浏览、搜索、管理文件；友好的"最近"标签，可隐藏内部 / 系统文件
- **快照** — 定时加密快照，GFS 保留策略，回收站与版本管理
- **P2P 镜像同步** — 离线友好的同步引擎：变更游标 + 批量原子上传，跨设备镜像
- **目录绑定** — 桌面端绑定本地文件夹，通过 FS watcher 自动同步（附周期兜底）
- **Agent 工作空间** — 每个 Agent / 群组在储物袋中拥有工作空间；Agent 简历（`resume.md`）存放于此，可用 `shepaw store` 读写
- **WebDAV 导出与备份** — 导出到 WebDAV、恢复、管理快照
- **NexusPouch / Storage Node** — 可选的无头 Go store master，扫码配对 + mDNS 发现，经 Noise 加密 WebSocket 提供 `store.*` 帧服务

### P2P 设备与 She 网络
- **设备配对** — 通过二维码、深链或扫码配对设备；握手由 **Noise Protocol** 加密（X25519 + ChaCha20-Poly1305）
- **Agent-over-Peer 与储物袋同步** — 把本地 Agent 共享给配对设备，并在设备间同步储物袋空间
- **Channel 隧道** — 主动维护到 channel server 的隧道，让外网 Peer 能跨网络连入本机
- **She 网络** — 多设备间 She 实例的在线状态广播与记忆交换

### 安全与隐私
- 本地优先存储（SQLite）；敏感凭证走平台 Secure Storage——无强制云后端
- 密码 + 生物识别（Face ID / Touch ID / 指纹）锁屏保护
- API Key 加密存储、ACP 权限审批（Agent 主动行为需授权）、OS 工具按风险分级（safe / lowRisk / highRisk，含确认弹窗 + 沙箱策略）
- Peer 通道端到端加密（Noise Protocol）；OS 工具沙箱执行
- 加密保险库备份与恢复（密码保护的快照，改密后自动重新加密）
- 推理日志审计（Token 消耗、响应时间、错误记录）

### 跨平台支持
- iOS / Android / macOS / Windows
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
flutter run -d android     # Android
```

### 构建发布包

```bash
flutter build apk --release    # Android
flutter build ios --release    # iOS（需 macOS + Xcode）
flutter build macos --release  # macOS
```

Windows 构建请使用专用脚本（详见 [BUILD_GUIDE.md](BUILD_GUIDE.md)）：

```powershell
.\build_windows.ps1
```

详细构建说明请参考 [BUILD_GUIDE.md](BUILD_GUIDE.md)。

---

## 支持的 LLM 提供商

| 类型 | 提供商 |
|------|--------|
| 云端 | OpenAI (GPT-4 / GPT-4o)、Anthropic Claude、Google Gemini、Grok、DeepSeek、Qwen（通义千问）、GLM（智谱）、Kimi（月之暗面）、Hunyuan（腾讯混元）、OpenRouter |
| 本地 | Ollama（llama3、llava 等任意本地模型） |
| 自定义 | 任何兼容 OpenAI API 的服务 |

---

## 项目结构

```
shepaw/
├── lib/
│   ├── main.dart                        # 应用入口（主窗口 + 子窗口识别）
│   ├── sub_window_app.dart              # 桌面端多窗口管理
│   ├── app_bootstrap.dart               # 启动编排
│   ├── service_locator.dart             # get_it 组合根
│   ├── models/                          # 数据模型（38 个）
│   │   ├── agent.dart                   # Agent 模型
│   │   ├── remote_agent.dart            # Remote Agent (ACP)
│   │   ├── channel.dart                 # Channel / 会话模型
│   │   ├── message.dart                 # 消息模型
│   │   ├── model_routing_config.dart    # 多模态路由配置
│   │   ├── workflow_models.dart         # Flow 工作流模型
│   │   └── ...
│   ├── screens/                         # 页面（57 个）
│   │   ├── adaptive_home_screen.dart    # 自适应主页（移动 / 桌面）
│   │   ├── chat_screen.dart             # 聊天界面
│   │   ├── storage_space_screen.dart    # 储物袋总览
│   │   ├── storage_browser_screen.dart  # 储物袋文件浏览
│   │   ├── remote_agent_detail_screen.dart  # Agent 详情与配置
│   │   └── ...
│   ├── widgets/                         # UI 组件（73 个）
│   │   ├── chat/                        # 聊天组件（气泡、面板、菜单）
│   │   ├── workflow/                    # Flow 任务看板组件
│   │   ├── storage/                     # 储物袋组件
│   │   ├── approval/                    # 审批横幅组件
│   │   └── ...
│   ├── services/                        # 核心服务（78+ 文件）
│   │   ├── chat_service.dart            # 聊天服务（消息处理中心）
│   │   ├── local_database_service.dart  # 数据库服务（SQLite）
│   │   ├── acp_agent_connection.dart    # ACP 连接管理（WebSocket）
│   │   ├── local_llm_agent_service.dart # 本地 LLM Agent 服务
│   │   ├── group/                       # 群组编排引擎
│   │   ├── workflow/                    # Flow 工作流引擎
│   │   ├── session/                     # 会话历史与压缩
│   │   ├── mailbox/                     # 收件箱与邮箱回复路由
│   │   ├── database/                    # 领域 DAO 扩展
│   │   ├── model_registry.dart          # AI 模型注册表
│   │   ├── skill_registry.dart          # 技能注册表
│   │   ├── cli_tool_registry.dart       # 外部 CLI 工具注册表
│   │   └── ...
│   ├── storage/                         # 储物袋引擎
│   │   ├── store_service.dart           # Store 协议服务
│   │   ├── sync_engine.dart             # P2P 同步引擎
│   │   ├── snapshot_service.dart        # 加密快照
│   │   ├── folder_binding_service.dart  # 目录绑定（FS watcher）
│   │   ├── webdav_export_service.dart   # WebDAV 导出
│   │   └── ...
│   ├── peer/                            # 设备配对与 P2P（Noise E2E）
│   │   ├── services/                    # 配对 / 连接 / agent host
│   │   ├── screens/                     # 配对 UI 页面
│   │   └── models/                      # 配对设备模型
│   ├── she_network/                     # She 网络（在线状态 + 记忆交换）
│   ├── task/                            # 定时任务（cron）
│   ├── clis/                            # ShePaw CLI（Agent 命令树）
│   │   └── shepaw/                      # shepaw <namespace> <command>
│   ├── controllers/                     # Chat / 会话列表协调器
│   ├── providers/                       # 轻量全局配置（Provider）
│   ├── config/                          # 应用 / 环境 / 功能开关配置
│   ├── theme/                           # 应用主题
│   ├── l10n/                            # 国际化（EN / ZH）
│   └── utils/                           # 工具类
├── test/                                # 测试（179 个文件）
├── docs/                                # 文档
│   ├── USER_GUIDE.md                    # 用户使用指南（中文）
│   ├── USER_GUIDE_EN.md                 # User Guide (English)
│   ├── agent_integration_guide.md       # ACP 协议集成指南
│   ├── remote_llm_agent_integration.md  # Remote LLM Agent 接入指南（中文）
│   ├── remote_llm_agent_integration_en.md  # Remote LLM Agent Integration Guide (EN)
│   ├── storage_protocol_spec.md         # Store 协议规范
│   ├── tool_model_architecture.md       # 工具模型系统文档
│   └── gorup_chat_flow.md               # Group Channel 流程文档
├── storage-node/                        # 无头 Store master（Go，可选）
├── cli-tools/                           # 外部 CLI 工具包（如 Brave 搜索）
├── android/ ios/ macos/ windows/        # 各平台入口
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

# 运行测试（CI 排除插件集成标签）
flutter test --exclude-tags=needs-plugins

# 运行特定测试
flutter test test/models/
flutter test test/integration/
```

---

## 技术栈

| 类别 | 技术 |
|------|------|
| 框架 | Flutter 3.x / Dart 3.0+ |
| DI / 业务服务 | `get_it` + Stream / ChangeNotifier |
| UI 局部状态 | `StatefulWidget` / `setState` |
| 轻量全局配置 | Provider + ChangeNotifier（`lib/providers/`） |
| 数据库 | SQLite（`sqflite`）+ 领域 DAO extension |
| 向量 / Embedding | `veda` 向量数据库、`tflite_flutter` |
| 敏感凭证 | `flutter_secure_storage`（Keychain / Keystore）via `SecureKeyManager` |
| 本地偏好 | SharedPreferences |
| 网络 | Dio、HTTP、`web_socket_channel`（ACP / Peer / Channel 隧道）、`multicast_dns`（mDNS 发现） |
| 端到端加密 | Noise Protocol（`cryptography`）— X25519 + ChaCha20-Poly1305 |
| 安全 | crypto、encrypt、local_auth、OS 工具确认门 + 沙箱策略 |
| UI | Material Design 3、flutter_markdown、flutter_highlight、flutter_svg、cached_network_image |
| 多媒体 | image_picker、record、audioplayers、file_picker、open_file |
| 桌面 | desktop_multi_window、pasteboard、watcher（目录绑定） |
| 通知 | flutter_local_notifications、local_notifier（Windows） |
| 权限 / 后台 | permission_handler、flutter_foreground_task、workmanager、wakelock_plus |
| 二维码配对 | mobile_scanner、qr_flutter |
| 定时任务 | 类 cron 调度（`task/`） |

---

## 文档

| 文档 | 说明 |
|------|------|
| [用户使用指南（中文）](docs/USER_GUIDE.md) | 面向最终用户的完整功能说明 |
| [User Guide (English)](docs/USER_GUIDE_EN.md) | End-user guide in English |
| [构建指南](BUILD_GUIDE.md) | 各平台详细构建说明 |
| [开发指南](DEVELOPMENT.md) | 代码规范和工作流程 |
| [商店上架清单](docs/STORE_RELEASE_CHECKLIST.md) | PrivacyInfo、深链、商店素材核对 |
| [Agent 接入指南](docs/agent_integration_guide.md) | ACP 协议集成文档（SDK 参考） |
| [Remote LLM Agent 接入指南](docs/remote_llm_agent_integration.md) | 第三方 Remote Agent 完整接入文档（中文） |
| [Remote LLM Agent Integration Guide](docs/remote_llm_agent_integration_en.md) | Third-party Remote Agent integration guide (English) |
| [Store 协议规范](docs/storage_protocol_spec.md) | `store://` 协议规范（Dart + Go 权威实现） |
| [工具模型架构](docs/tool_model_architecture.md) | 工具模型系统说明 |
| [群组聊天流程](docs/gorup_chat_flow.md) | Group Channel 流程文档 |

---

## 许可证

[MIT License](LICENSE)

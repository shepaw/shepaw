# Claude 工作规范

## AI 中间产物目录

**所有由 AI 推理过程生成的文件，必须保存在 `.ai_workspace/` 目录下。**

包括但不限于：
- 代码分析报告（`*_ANALYSIS.md`、`*_FINDINGS.md`）
- 架构图和可视化文档（`*_DIAGRAM.md`、`*_VISUAL*.md`）
- 快速参考文档（`*_QUICK_REFERENCE.md`、`*_INDEX.md`）
- 探索摘要（`*_EXPLORATION*.md`、`*_SUMMARY.md`）
- 实现指南和工作日志（`*_GUIDE.md`、`*_WORK_LOG.md`）
- 任何临时性的中间分析文档

**读取已有中间产物时，优先从 `.ai_workspace/` 目录查找。**

项目根目录只保留正式文档：`README.md`、`README_CN.md`、`README_EN.md`、`BUILD_GUIDE.md`。

`.ai_workspace/` 已加入 `.gitignore`，不会被提交到版本库。

## 状态管理约定

团队统一按以下范式选型，避免再引入新的状态管理框架：

| 场景 | 方式 | 说明 |
|------|------|------|
| 业务状态（Chat、Peer、Agent 列表等） | Service + Stream / ChangeNotifier | 通过 `getIt` 获取；UI 用 `StreamBuilder` / `listen` / `ListenableBuilder` |
| UI 局部状态（表单、展开折叠、滚动） | `StatefulWidget` + `setState` | 不跨页面共享 |
| 全局轻量配置（Locale、通知开关） | Provider + ChangeNotifier | 见 `lib/providers/` |

**不要**再引入 GetX / Riverpod / Bloc 等新框架，除非有明确 RFC 并清理旧路径。

### 依赖注入

- 组合根：`lib/service_locator.dart`（`get_it`）
- 启动编排：`lib/app_bootstrap.dart`（`AppBootstrap.initialize`）
- 新增全局共享服务 → 在 `setupServiceLocator` / `registerBootstrapServices` 注册，禁止新增顶层 `late` 全局变量

### 遗留路径（待清理，勿扩大使用面）

- `lib/providers/app_state.dart` + `WebSocketService`：旧 client-server 模型，仅少量 UI 仍读 `currentUser`；新功能不要依赖
- 巨型 Screen / Controller：拆分时优先按领域抽协作类 / DAO / 独立 Widget，Controller 只做组合

## 测试与 CI

- CI：`.github/workflows/ci.yml` — `flutter analyze` + `flutter test --exclude-tags=needs-plugins`
- 依赖 path_provider / 平台通道的集成测试打 `@Tags(['needs-plugins'])`，本地可单独跑
- 纯逻辑优先放 `test/services/`、`test/models/`、`test/peer/`（单元测试）

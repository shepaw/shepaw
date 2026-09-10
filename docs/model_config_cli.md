# 模型配置 CLI（shepaw models）与 She 需要知道的事

> 用途：让 She 通过内嵌 CLI（LLM function calling 调用 `shepaw` 工具树）帮用户把模型配置好。
> 典型场景：DeepSeek / OpenAI 等厂商发布最新模型时，用户说一句"帮我配上"，She 就能核对模型 id、
> 加模型、补 Key、并把某个 Agent 的主对话模型切换过去。
>
> 说明：**本机不维护、也不依赖任何"远端模型目录"**（官方目录导入功能已下线，相关 UI 与服务
> 均已移除）。新增模型一律手动添加。
>
> 本文对应实现：
> - 命名空间：`lib/clis/shepaw/models/`（`models_namespace.dart` + 7 个子命令）
> - 注册与提示词：`lib/clis/shepaw/shepaw_cli.dart`、`lib/services/cli_namespace_registry.dart`、
>   `lib/services/she_service.dart`（`buildMetaCognitionBlock`）

---

## 1. 模型的"配置"在 ShePaw 里到底指什么

用户/Agent 使用的每个 LLM 端点都是一个 **ModelDefinition**（`lib/models/model_definition.dart`），
全局存放在 ModelRegistry（SharedPreferences + SecureKeyManager 存 Key）。一个模型定义包含：

| 字段 | 含义 | 示例 |
|------|------|------|
| `display_name` | 界面/下拉显示名 | `DeepSeek Chat` |
| `route.model` | 厂商 API 要求的**精确模型 id** | `deepseek-chat` |
| `route.api_base` | API 基址 | `https://api.deepseek.com/v1` |
| `route.provider` | 协议类型（openai / claude / glm） | `openai` |
| `route.api_key` | 密钥（安全存储，不外显） | — |
| `model_types` | 能力类型 | `text`、`imageUnderstanding`… |

Agent 只存**模型定义的 id**：主对话模型 = `metadata['main_model_id']`；
分模态（图/音/视频/生成）可另配 `scenario_models`。运行时经 ModelRegistry 解析出完整 route 发请求
（`LocalLLMAgentService._resolveModelConfig`）。

> 所以"帮用户配置好模型"由两件事组成：**① 把模型定义建好（含 Key/能力标注）；② 把它指给某个 Agent**。

---

## 2. 命令速览

```
shepaw models list                        # 本机已配置的模型 + 各被哪些 Agent 引用（脱敏）
shepaw models show --id <id>              # 单个模型完整信息（脱敏）
shepaw models providers                   # 内置服务商预设（apiBase/协议/是否必填 Key）+ 配置须知
shepaw models add --provider DeepSeek --name deepseek-chat [--display_name ...]
                                          # 手动添加（自动带出服务商预设与缓存 Key）
shepaw models update --id <id> --api_key <key>            # 补 Key
shepaw models update --id <id> --display_name "..." --types text,imageUnderstanding
shepaw models update --id <id> --clear_api_key            # 移除 Key
shepaw models remove --id <id> [--yes]    # 删除（仍被 Agent 引用时需 --yes）
shepaw models agent-main --agent <id|名> --model <id|模型名>   # 把模型设为某 Agent 主对话模型
shepaw models agent-main --agent She --unset                      # 解除主模型
```

任意命令加 `flags={"help":""}`（或 `shepaw models <cmd> --help`）可看逐字段说明。
顶层发现：`shepaw help` → `shepaw models` → `shepaw models <cmd> --help`。

---

## 3. DeepSeek 发布新模型：She 的完整操作序列（知识内容）

She 在提示词/工具描述中会被告知下面这些"她需要知道的事"（内容本身放在
`ModelsNamespace.getHelpAsync()` 的 `what_she_needs_to_know` / `rules` /
`workflow_deepseek_example`，以及 `she_service.dart` 的 meta-cognition 块里）：

1. **先看现状，不要假设**：`shepaw models list`（拿 id、看谁在用）、
   `shepaw models providers`（服务商预设：DeepSeek → openai 协议、`https://api.deepseek.com/v1`、必填 Key）。
2. **新模型的 id 必须核对，不能猜**：没有远端目录，model id 不是 She 自己编的 ——
   用 `shepaw tools web.search` 查厂商官方文档/API 页，拿到**精确 model id** 后再
   `shepaw models add --provider DeepSeek --name <精确id> --types text`。
   （例如用户口头说的"最新的 R1"可能对应 `deepseek-reasoner` 或新版本号，必须以上游文档为准。）
3. **Key 处理（安全红线）**：
   - `add` 时若该 `api_base` 已缓存过 Key（同基址的其它模型，或 provider 级缓存）会自动复用，
     命令返回里只给 `api_key_source`，绝不回显明文；
   - 需要 Key 且没有缓存 → 返回 `needs_api_key: true`，She 向用户说明：
     `shepaw models update --id <id> --api_key <key>`（或用户去"模型管理"页补填）；
   - 输出永远只有 `has_api_key` 布尔，**任何回复/汇总都不得打印 API Key**。
4. **配上 ≠ 用上**：`add` 只是把模型放进注册中心（下拉可选）。用户想切换（例如让 She 本人改用
   新模型）才执行 `shepaw models agent-main --agent She --model <id>`；影响的是 `main_model_id`，
   与编辑页"主对话模型"同一字段。**切模型前先与用户确认**。
5. **生效时点与例外**：`agent-main` 从该 Agent 的**下一条消息**生效；若该 Agent 对图/音/视频配过
   显式 `scenario_models`，那些模态仍走场景模型（`agent-main` 输出会列出被覆盖的模态提示 She）。
6. **只改本地 LLM Agent**：peer/远端 ACP Agent 的模型由对端自管，`agent-main` 会拒绝；
   非 She 的 Agent 只能改自己（She 可改任何本地 Agent）。
7. **删除安全**：`models remove` 前先 `list`/`show` 看引用；仍被引用默认拒绝，除非用户明确要求并 `--yes`。

---

## 4. She 的知识注入位置（本特性的"内容"改动）

| 位置 | 内容 |
|------|------|
| `shepaw` 工具描述（`shepaw_cli.dart` `_builtinToolDescription`） | 一句话：模型配置场景 → `namespace=models`，先 list；新模型 id 用 web.search 核对后 add；与用户确认、不打印 Key |
| She meta-cognition 块（`she_service.dart` `buildMetaCognitionBlock`） | Hard rules 一条 + Discover on demand 一行：模型配置走 `shepaw models` |
| `models` 命名空间 help（`ModelsNamespace.getHelpAsync`） | `what_she_needs_to_know`（6 条知识）、`rules`、`workflow_deepseek_example` |
| 各子命令 `--help`（`getHelp`/`flags`/`examples`） | 逐字段用法、安全提示、deepseek 示例 |

非 She Agent 的 meta CLI 引导块（`_nonSheMetaCliBlock`）默认**不**教 models 命令 —— 模型配置是
主控侧（用户/She）的事；其它 Agent 仍可通过 `shepaw help` 发现，但不会被主动引导。

---

## 5. 与既有系统的对齐点

- **同一个注册中心**：CLI 的增删改直接走 `ModelRegistry.instance.add/update/delete`
  （`model_registry.dart`），与"模型管理/编辑页"写的是同一份数据；Key 由
  `ModelRegistry._persist` + `SecureKeyManager` 处理，与 UI 完全一致。
- **同一个字段**：`agent-main` 写 `metadata['main_model_id']` / `llm_provider`（sentinel）并移除旧
  的 `llm_model/llm_api_base/llm_api_key`，与 `remote_agent_detail_screen.dart` 的保存逻辑一致，
  经 `RemoteAgentService.updateAgent` 持久化并推送对端。
- **去重规则**：`add` 拒绝 `(route.model, api_base)` 已存在；`update --model/--api_base` 改完后同样不产生重复。
- **服务商预设**：`providers` / `add` 读取 `lib/models/llm_provider_config.dart` 的 `llmProviders`
  （协议类型、默认 apiBase、是否必填 Key），与"模型管理/编辑页"的服务商选择一致。目前包含
  OpenAI、Claude、Gemini、Grok、DeepSeek、Qwen、GLM、Kimi、Hunyuan、Ollama、OpenRouter、
  腾讯云 TokenHub 共 12 个预设。

---

## 6. 后续可选增强（不在本次范围）

- `models test` 连通性探测（发一个极短请求验证 Key/endpoint）。
- 新模型提醒：She 定期核对厂商发布页并主动告知用户（需用户授权自动执行）。

---

## 7. 模型列表在线拉取（UI）

模型编辑页的「获取模型列表」按钮由预设能力位驱动，三条分支：

| 预设 | 分支 | 实现 |
|------|------|------|
| OpenRouter | 专用 | `OpenRouterService`（带 modality / pricing 元数据） |
| Ollama | 专用 | `OllamaService`（本地 `/api/tags`，带 family / parameter_size） |
| TokenHub 等任意 OpenAI 兼容厂商 | 通用 | `OpenAiCompatibleModelsService`：`GET {apiBase}{modelsPath}` |

**开启方式**：给 `LLMProviderConfig` 的 `modelsPath` 赋值（如 `'/models'`）。预设表里为
`null` 的厂商不显示该按钮，走手输模型 ID。协议要求 `GET {apiBase}/models` 返回标准
OpenAI 形态（`{"object":"list","data":[{"id",...}]}`），顶层裸数组亦可。

错误处理：401/403 → `AuthException`（Key 无效或无权限）；404 → `ApiException`
（该厂商未实现模型列表接口，提示改手输 ID）；其它非 200 → `ApiException`。服务按
`(apiBase, modelsPath)` 分键做 1 小时缓存，UI 侧一律 `forceRefresh: true`。

> 地域提示：腾讯云 TokenHub 不支持跨地域调用。预设预填的是广州
> `https://tokenhub.tencentmaas.com/v1`；新加坡为 `https://tokenhub-intl.tencentmaas.com/v1`，
> 硅谷为 `https://tokenhub-us.tencentmaas.com/v1`，需在 API Base 输入框自行改填。

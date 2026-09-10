/// LLM 服务商配置
class LLMProviderConfig {
  final String name;
  final String providerType; // openai / claude / glm
  final String defaultApiBase;
  final String defaultModel;
  /// Default vision-capable model suggestion when creating a new model entry.
  /// Not used at runtime — configure per-agent scenario models instead.
  final String? defaultVisionModel;
  /// 相对 [defaultApiBase] 的模型列表路径（OpenAI 兼容 `GET {apiBase}{modelsPath}`）。
  /// null 表示不提供在线模型列表拉取。
  final String? modelsPath;
  final List<String> models;
  final bool requiresApiKey;
  final String icon;

  const LLMProviderConfig({
    required this.name,
    required this.providerType,
    required this.defaultApiBase,
    required this.defaultModel,
    this.defaultVisionModel,
    this.modelsPath,
    required this.models,
    required this.requiresApiKey,
    required this.icon,
  });
}

/// 预定义的 LLM 服务商列表
const List<LLMProviderConfig> llmProviders = [
  LLMProviderConfig(
    name: 'OpenAI',
    providerType: 'openai',
    defaultApiBase: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
    defaultVisionModel: 'gpt-4o',
    models: [],
    requiresApiKey: true,
    icon: '🟢',
  ),
  LLMProviderConfig(
    name: 'Claude',
    providerType: 'claude',
    defaultApiBase: 'https://api.anthropic.com/v1',
    defaultModel: 'claude-sonnet-4-20250514',
    defaultVisionModel: 'claude-sonnet-4-20250514',
    models: [],
    requiresApiKey: true,
    icon: '🟠',
  ),
  LLMProviderConfig(
    name: 'Gemini',
    providerType: 'openai',
    defaultApiBase: 'https://generativelanguage.googleapis.com/v1beta/openai',
    defaultModel: 'gemini-2.0-flash',
    defaultVisionModel: 'gemini-2.0-flash',
    models: [],
    requiresApiKey: true,
    icon: '🔷',
  ),
  LLMProviderConfig(
    name: 'Grok',
    providerType: 'openai',
    defaultApiBase: 'https://api.x.ai/v1',
    defaultModel: 'grok-3',
    defaultVisionModel: 'grok-2-vision-1212',
    models: [],
    requiresApiKey: true,
    icon: '⚫',
  ),
  LLMProviderConfig(
    name: 'DeepSeek',
    providerType: 'openai',
    defaultApiBase: 'https://api.deepseek.com/v1',
    defaultModel: 'deepseek-chat',
    models: [],
    requiresApiKey: true,
    icon: '🔵',
  ),
  LLMProviderConfig(
    name: 'Qwen',
    providerType: 'openai',
    defaultApiBase: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    defaultVisionModel: 'qwen-vl-plus',
    models: [],
    requiresApiKey: true,
    icon: '🟣',
  ),
  LLMProviderConfig(
    name: 'GLM',
    providerType: 'glm',
    defaultApiBase: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4.7',
    defaultVisionModel: 'glm-4v-flash',
    models: [],
    requiresApiKey: true,
    icon: '🔴',
  ),
  LLMProviderConfig(
    name: 'Kimi',
    providerType: 'openai',
    defaultApiBase: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    models: [],
    requiresApiKey: true,
    icon: '🌙',
  ),
  LLMProviderConfig(
    name: 'Hunyuan',
    providerType: 'openai',
    defaultApiBase: 'https://api.hunyuan.cloud.tencent.com/v1',
    defaultModel: 'hunyuan-lite',
    defaultVisionModel: 'hunyuan-vision',
    models: [],
    requiresApiKey: true,
    icon: '💜',
  ),
  LLMProviderConfig(
    name: 'Ollama',
    providerType: 'openai',
    defaultApiBase: 'http://localhost:11434/v1',
    defaultModel: 'llama3',
    defaultVisionModel: null,
    models: [],
    requiresApiKey: false,
    icon: '⚪',
  ),
  LLMProviderConfig(
    name: 'OpenRouter',
    providerType: 'openai',
    defaultApiBase: 'https://openrouter.ai/api/v1',
    defaultModel: 'openai/gpt-4o',
    defaultVisionModel: 'openai/gpt-4-vision',
    models: [],
    requiresApiKey: true,
    icon: '🔄',
  ),
  // 追加在末尾：多处按 providerType 取「第一个命中」的预设（UI 预选第二轮、
  // CLI resolveProvider），追加可保证 index 0 仍是 OpenAI，存量行为不变。
  LLMProviderConfig(
    name: 'TokenHub',
    providerType: 'openai',
    defaultApiBase: 'https://tokenhub.tencentmaas.com/v1',
    defaultModel: 'hy3',
    defaultVisionModel: 'hy-vision-2.0-instruct',
    models: [],
    modelsPath: '/models',
    requiresApiKey: true,
    icon: '☁️',
  ),
];

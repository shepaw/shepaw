import '../../cli_base.dart';
import '../../../models/llm_provider_config.dart';
import 'models_cli_helpers.dart';

/// 内置 LLM 服务商预设清单 —— She 配置模型时需要知道的"服务商知识库"。
///
/// 每个服务商预设给出默认 apiBase、providerType（决定请求协议：
/// openai = OpenAI 兼容 / claude / glm）与是否必填 API Key。
class ModelsProvidersCommand extends CliCommand {
  @override
  String get name => 'providers';

  @override
  String get description =>
      'List built-in LLM provider presets (api base, protocol, key policy)';

  @override
  String get usage => 'shepaw models providers';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['note'] =
        'Knowledge for configuring models: provider_type openai/claude/glm decides the '
        'request protocol; the model flag --name must be the exact model id the provider '
        'API expects (e.g. deepseek-chat). Newly released models are added manually '
        'after verifying the id against the provider official docs via '
        '"shepaw tools web.search".';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final providers = llmProviders.map(providerSummary).toList();
    return {
      'providers': providers,
      'count': providers.length,
      'facts': [
        'There is no built-in remote model directory — models are added manually. '
            'When a provider (e.g. DeepSeek) releases a model, confirm the exact '
            'model id from its official docs (shepaw tools web.search), then run '
            'shepaw models add --provider <provider label> --name <model id>.',
        'provider_type "openai" means OpenAI-compatible chat/completions '
            '(OpenAI, DeepSeek, Qwen, Kimi, Hunyuan, TokenHub, Ollama, OpenRouter, Gemini-compatible).',
        'API keys are stored securely and never printed: outputs expose only has_api_key. '
            'When adding a model under an api_base that already has a key, the key is '
            'reused automatically.',
        'A model only takes effect for an agent once assigned: '
            'shepaw models agent-main --agent <agent> --model <model_id>.',
      ],
    };
  }
}

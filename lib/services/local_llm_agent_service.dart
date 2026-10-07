import 'dart:async';
import 'dart:io';

import '../models/agent_scenario_models.dart';
import '../models/attachment_data.dart';
import '../models/llm_stream_event.dart';
import '../models/model_routing_config.dart';
import '../models/remote_agent.dart';
import 'prompt_cache.dart';
import 'model_registry.dart';

/// 本机不再调用模型。对话和群编排都在 Hub 上。
const String hubModelNotice = '模型已经搬到 Hub，这台设备不再调用。';

/// Local LLM Agent Service
///
/// 以前直接请求 OpenAI / Claude / GLM。模型调用已经搬到 Hub，
/// [chat] 和 [chatRound] 只返回一句说明，不再打开网络连接。
class LocalLLMAgentService {
  static final LocalLLMAgentService instance = LocalLLMAgentService._();
  LocalLLMAgentService._();

  /// Whether [agent] is a local LLM agent.
  bool isLocalAgent(RemoteAgent agent) => agent.isLocal;

  static const _cancelKeyZoneKey = #shepawLlmCancelKey;

  final Map<Object, Set<HttpClient>> _clientsByKey = {};

  /// Run [body] under a cancel [key]. 没有在飞的 HTTP 请求了，保留这个入口
  /// 是因为调用方还按这个形状包一层。
  Stream<LLMStreamEvent> runWithCancelKey(
    Object key,
    Stream<LLMStreamEvent> Function() body,
  ) {
    return runZoned(body, zoneValues: {_cancelKeyZoneKey: key});
  }

  /// Abort running streaming requests. 模型连接已经拆掉，这里只关掉还留着的客户端。
  void abort([Object? key]) {
    final Iterable<HttpClient> clients;
    if (key == null) {
      clients = _clientsByKey.values.expand((s) => s).toList();
      _clientsByKey.clear();
    } else {
      final set = _clientsByKey.remove(key);
      clients = set?.toList() ?? const [];
    }
    for (final c in clients) {
      c.close(force: true);
    }
  }

  /// Return the effective provider type string for [agent] (e.g. 'claude',
  /// 'openai', 'glm').
  String resolveProviderType(RemoteAgent agent) {
    return _resolveModelConfig(agent, null).providerType;
  }

  /// 不再请求模型。调用方拿到同一句说明。
  Stream<LLMStreamEvent> chat({
    required RemoteAgent agent,
    required String message,
    List<Map<String, dynamic>>? history,
    bool enableUITools = true,
    bool? includeShepawCli,
    String? systemPromptOverride,
    BuiltSystemPrompt? layeredSystemPrompt,
    List<AttachmentData>? attachments,
    bool skipSheMemoryStack = false,
    List<Map<String, dynamic>>? extraTools,
    Set<String> excludeUIToolNames = const {},
    Set<String>? enabledCliCommands,
    Set<String>? extraCliAllowlist,
  }) async* {
    yield LLMTextEvent(hubModelNotice);
    yield LLMDoneEvent(stopReason: 'stop');
  }

  /// 不再请求模型。调用方拿到同一句说明。
  Stream<LLMStreamEvent> chatRound({
    required RemoteAgent agent,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    String? systemPrompt,
    BuiltSystemPrompt? layeredSystemPrompt,
    List<AttachmentData>? attachments,
  }) async* {
    yield LLMTextEvent(hubModelNotice);
    yield LLMDoneEvent(stopReason: 'stop');
  }

  ResolvedModelConfig _resolveModelConfig(
    RemoteAgent agent,
    List<AttachmentData>? attachments,
  ) {
    final semanticTypes =
        attachments?.map((a) => a.semanticType).toList() ?? [];
    final modality = ModelRoutingConfig.detectModality(semanticTypes);
    final mainModelId = agent.metadata['main_model_id'] as String?;

    final scenarioDef = agent.scenarioModels.resolveDefinition(
      modality,
      mainModelId: mainModelId,
      registry: ModelRegistry.instance,
    );
    if (scenarioDef != null) {
      return AgentScenarioModels.configFromDefinition(scenarioDef);
    }

    if (mainModelId != null) {
      final def = ModelRegistry.instance.getById(mainModelId);
      if (def != null) {
        return AgentScenarioModels.configFromDefinition(def);
      }
    }

    final fallbackProvider = agent.metadata['llm_provider'] as String? ?? 'openai';
    final fallbackModel = agent.metadata['llm_model'] as String? ?? '';
    final fallbackApiBase = agent.metadata['llm_api_base'] as String? ?? '';
    final fallbackApiKey =
        repairUtf16Garbled(agent.metadata['llm_api_key'] as String? ?? '');

    return ResolvedModelConfig(
      providerType: fallbackProvider,
      model: fallbackModel,
      apiBase: fallbackApiBase,
      apiKey: fallbackApiKey,
    );
  }

  /// Whether [error] is a transient LLM-call failure worth retrying.
  static bool isRetryableLlmError(Object error) {
    return error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is HttpException;
  }
}

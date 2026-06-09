import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/remote_agent.dart';
import '../models/llm_stream_event.dart';
import '../models/attachment_data.dart';
import '../models/model_routing_config.dart';
import '../models/agent_scenario_models.dart';
import 'model_registry.dart';
import 'ui_component_registry.dart';
import 'logger_service.dart';
import 'she_service.dart';
import '../clis/shepaw/shepaw_cli.dart';

/// Local LLM Agent Service
///
/// Directly calls LLM HTTP APIs (OpenAI-compatible / Claude / GLM) and
/// returns streaming responses. No WebSocket or remote endpoint needed.
class LocalLLMAgentService {
  static final LocalLLMAgentService instance = LocalLLMAgentService._();
  LocalLLMAgentService._();

  /// Whether [agent] is a local LLM agent.
  ///
  /// 统一判定入口为 [RemoteAgent.isLocal]；此方法仅作向后兼容的薄封装，
  /// 不再重复判定逻辑。新代码请直接使用 `agent.isLocal`。
  bool isLocalAgent(RemoteAgent agent) => agent.isLocal;

  /// Zone key carrying the per-request cancel key. Set via [runWithCancelKey];
  /// read at [HttpClient] registration sites so each in-flight request is
  /// associated with its own cancel key, enabling isolated cancellation.
  static const _cancelKeyZoneKey = #shepawLlmCancelKey;

  /// Sentinel bucket for requests started without a cancel key (legacy /
  /// fire-and-forget). [abort] with no argument targets every bucket.
  static final Object _unkeyed = Object();

  /// In-flight [HttpClient]s grouped by cancel key.
  final Map<Object, Set<HttpClient>> _clientsByKey = {};

  /// Run [body] (which invokes [chat] / [chatRound]) under a cancel [key], so
  /// every HTTP client it spawns is tagged with that key. Cancelling via
  /// `abort(key)` then only tears down this request's streams — other concurrent
  /// agents (and the desktop's own chats) are unaffected.
  ///
  /// Relies on `async`/`async*` bodies capturing [Zone.current] at invocation:
  /// because the stream is created inside the zoned [body], its later execution
  /// (and nested HTTP client creation) runs in this zone.
  Stream<LLMStreamEvent> runWithCancelKey(
    Object key,
    Stream<LLMStreamEvent> Function() body,
  ) {
    return runZoned(body, zoneValues: {_cancelKeyZoneKey: key});
  }

  Object _currentCancelKey() =>
      (Zone.current[_cancelKeyZoneKey] as Object?) ?? _unkeyed;

  void _registerClient(HttpClient client) {
    (_clientsByKey[_currentCancelKey()] ??= {}).add(client);
  }

  void _unregisterClient(HttpClient client) {
    // Remove from whichever bucket holds it (robust against zone mismatch).
    _clientsByKey.removeWhere((key, set) {
      set.remove(client);
      return set.isEmpty;
    });
  }

  /// Abort running streaming requests.
  ///
  /// - With a [key]: force-closes only that request's [HttpClient]s (isolated
  ///   per-agent cancellation). Used when a single chat is stopped.
  /// - Without a key: force-closes *all* in-flight requests (global stop).
  ///
  /// Force-closing causes the SSE `await for` loops to terminate with an error
  /// that is caught and silenced.
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
  /// 'openai', 'glm'). This is the same value used internally by [chat] to
  /// select the API format. Callers can use this to build multimodal content
  /// in the correct format before passing history to [chat].
  String resolveProviderType(RemoteAgent agent) {
    return _resolveModelConfig(agent, null).providerType;
  }

  /// Send a message and get a streaming response from the configured LLM.
  ///
  /// Model selection uses [RemoteAgent.scenarioModels] and [main_model_id]
  /// via [_resolveModelConfig].
  Stream<LLMStreamEvent> chat({
    required RemoteAgent agent,
    required String message,
    List<Map<String, dynamic>>? history,
    bool enableUITools = true,
    bool includeShepawCli = false,
    String? systemPromptOverride,
    List<AttachmentData>? attachments,
  }) async* {
    final resolved = _resolveModelConfig(agent, attachments);
    // For She agent, inject memory context into the system prompt
    final isEphemeralOverride = systemPromptOverride != null;
    String systemPrompt = systemPromptOverride ??
        (agent.metadata['system_prompt'] as String? ?? '');
    if (agent.metadata['is_she'] == true) {
      systemPrompt = await SheService.instance.buildSystemPromptWithMemory(
        systemPrompt,
        allowSoulSeed: !isEphemeralOverride,
        isEphemeralContext: isEphemeralOverride,
      );
    }

    if (resolved.apiBase.isEmpty) {
      throw Exception('LLM API Base URL is not configured');
    }
    if (resolved.model.isEmpty) {
      throw Exception('LLM model is not configured');
    }

    // Non-SSE path: plain JSON request/response
    if (!resolved.stream) {
      yield* _chatNonSSE(
        resolved: resolved,
        message: message,
        systemPrompt: systemPrompt,
        history: history,
        enableUITools: enableUITools,
        includeShepawCli: includeShepawCli,
        attachments: attachments,
      );
      return;
    }

    switch (resolved.providerType) {
      case 'claude':
        yield* _chatClaude(
          apiBase: resolved.apiBase,
          apiKey: resolved.apiKey,
          model: resolved.model,
          message: message,
          systemPrompt: systemPrompt,
          history: history,
          enableUITools: enableUITools,
          includeShepawCli: includeShepawCli,
          attachments: attachments,
        );
        break;
      case 'glm':
      case 'openai':
      default:
        // GLM is OpenAI-compatible
        yield* _chatOpenAI(
          apiBase: resolved.apiBase,
          apiKey: resolved.apiKey,
          model: resolved.model,
          message: message,
          systemPrompt: systemPrompt,
          history: history,
          enableUITools: enableUITools,
          includeShepawCli: includeShepawCli,
          attachments: attachments,
        );
        break;
    }
  }

  // =========================================================================
  // chatRound — multi-round tool calling support
  // =========================================================================

  /// Execute a single LLM round with a pre-built message list and tool
  /// definitions. Unlike [chat], the caller constructs the full messages array
  /// (including tool results from prior rounds) and supplies the combined tool
  /// list (UI + OS tools).
  ///
  /// Yields [LLMTextEvent], [LLMToolCallEvent], and a final [LLMDoneEvent]
  /// carrying the stop reason and raw assistant content for building the next
  /// round's message history.
  Stream<LLMStreamEvent> chatRound({
    required RemoteAgent agent,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    String? systemPrompt,
    List<AttachmentData>? attachments,
  }) {
    final resolved = _resolveModelConfig(agent, attachments);

    if (resolved.apiBase.isEmpty) {
      return Stream.error(Exception('LLM API Base URL is not configured'));
    }
    if (resolved.model.isEmpty) {
      return Stream.error(Exception('LLM model is not configured'));
    }

    // Non-SSE path: plain JSON request/response
    if (!resolved.stream) {
      return _chatRoundNonSSE(
        resolved: resolved,
        messages: messages,
        tools: tools,
        systemPrompt: systemPrompt,
      );
    }

    switch (resolved.providerType) {
      case 'claude':
        return _chatRoundClaude(
          apiBase: resolved.apiBase,
          apiKey: resolved.apiKey,
          model: resolved.model,
          messages: messages,
          tools: tools,
          systemPrompt: systemPrompt,
        );
      case 'glm':
      case 'openai':
      default:
        return _chatRoundOpenAI(
          apiBase: resolved.apiBase,
          apiKey: resolved.apiKey,
          model: resolved.model,
          messages: messages,
          tools: tools,
        );
    }
  }

  // ---------------------------------------------------------------------------
  // chatRound — OpenAI-compatible
  // ---------------------------------------------------------------------------

  Stream<LLMStreamEvent> _chatRoundOpenAI({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
  }) async* {
    final url = apiBase.endsWith('/')
        ? '${apiBase}chat/completions'
        : '$apiBase/chat/completions';

    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
    };
    if (tools.isNotEmpty) {
      requestBody['tools'] = tools;
    }

    final headers = {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
    final body = jsonEncode(requestBody);

    yield* _streamWithMultimodalFallback(
      stream: () => _streamSSEOpenAI(url: url, headers: headers, body: body),
      messages: messages,
      buildRetryStream: (degraded) {
        final retryBody = jsonEncode({...requestBody, 'messages': degraded});
        return _streamSSEOpenAI(url: url, headers: headers, body: retryBody);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // chatRound — Claude
  // ---------------------------------------------------------------------------

  Stream<LLMStreamEvent> _chatRoundClaude({
    required String apiBase,
    required String apiKey,
    required String model,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    String? systemPrompt,
  }) async* {
    final url = apiBase.endsWith('/')
        ? '${apiBase}messages'
        : '$apiBase/messages';

    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'max_tokens': 4096,
    };
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      requestBody['system'] = systemPrompt;
    }
    if (tools.isNotEmpty) {
      requestBody['tools'] = tools;
    }

    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    };
    final body = jsonEncode(requestBody);

    yield* _streamWithMultimodalFallback(
      stream: () => _streamSSEClaude(url: url, headers: headers, body: body),
      messages: messages,
      buildRetryStream: (degraded) {
        final retryBody = jsonEncode({...requestBody, 'messages': degraded});
        return _streamSSEClaude(url: url, headers: headers, body: retryBody);
      },
    );
  }

  // =========================================================================
  // Non-SSE (plain JSON) request path
  // =========================================================================

  /// Non-SSE chat for a single user message. Builds messages, calls
  /// [_postNonSSE], extracts content, and yields events.
  Stream<LLMStreamEvent> _chatNonSSE({
    required ResolvedModelConfig resolved,
    required String message,
    required String systemPrompt,
    List<Map<String, dynamic>>? history,
    bool enableUITools = true,
    bool includeShepawCli = false,
    List<AttachmentData>? attachments,
  }) async* {
    final messages = <Map<String, dynamic>>[];
    if (systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }
    if (history != null) {
      messages.addAll(history);
    }
    messages.add({'role': 'user', 'content': message});

    final url = _buildNonSSEUrl(resolved);
    final body = _buildNonSSERequestBody(resolved, messages);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (resolved.apiKey.isNotEmpty) 'Authorization': 'Bearer ${resolved.apiKey}',
    };

    try {
      final json = await _postNonSSE(url: url, headers: headers, body: body);

      final content = _extractResponseContent(json, resolved);
      if (content.isNotEmpty) {
        yield LLMTextEvent(content);
      }

      // Extract tool calls if present
      final toolCalls = _extractToolCalls(json, resolved);
      for (final tc in toolCalls) {
        yield tc;
      }

      yield LLMDoneEvent(
        stopReason: 'stop',
        rawAssistantMessage: {
          'role': 'assistant',
          if (content.isNotEmpty) 'content': content,
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  /// Non-SSE chat round with pre-built messages (for multi-round tool calling).
  Stream<LLMStreamEvent> _chatRoundNonSSE({
    required ResolvedModelConfig resolved,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    String? systemPrompt,
  }) async* {
    final url = _buildNonSSEUrl(resolved);
    final body = _buildNonSSERequestBody(resolved, messages);

    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (resolved.apiKey.isNotEmpty) 'Authorization': 'Bearer ${resolved.apiKey}',
    };

    try {
      final json = await _postNonSSE(url: url, headers: headers, body: body);

      final content = _extractResponseContent(json, resolved);
      if (content.isNotEmpty) {
        yield LLMTextEvent(content);
      }

      final toolCalls = _extractToolCalls(json, resolved);
      for (final tc in toolCalls) {
        yield tc;
      }

      yield LLMDoneEvent(
        stopReason: toolCalls.isNotEmpty ? 'tool_calls' : 'stop',
        rawAssistantMessage: {
          'role': 'assistant',
          if (content.isNotEmpty) 'content': content,
        },
      );
    } catch (e) {
      rethrow;
    }
  }

  /// POST a non-SSE request and return the parsed JSON response body.
  Future<Map<String, dynamic>> _postNonSSE({
    required String url,
    required Map<String, String> headers,
    required String body,
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    _registerClient(client);

    try {
      final request = await client.postUrl(uri);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.add(utf8.encode(body));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        LoggerService().error('Non-SSE API error ${response.statusCode} from $url', tag: 'LocalLLM');
        throw Exception('LLM API error (${response.statusCode}): $responseBody');
      }

      return jsonDecode(responseBody) as Map<String, dynamic>;
    } finally {
      _unregisterClient(client);
      client.close();
    }
  }

  /// Build the URL for a non-SSE request.
  ///
  /// Uses [resolved.apiPath] if set, otherwise falls back to the provider's
  /// default path (`/chat/completions`).
  String _buildNonSSEUrl(ResolvedModelConfig resolved) {
    final base = resolved.apiBase.endsWith('/')
        ? resolved.apiBase.substring(0, resolved.apiBase.length - 1)
        : resolved.apiBase;

    if (resolved.apiPath != null && resolved.apiPath!.isNotEmpty) {
      final path = resolved.apiPath!.startsWith('/')
          ? resolved.apiPath!
          : '/${resolved.apiPath!}';
      return '$base$path';
    }
    return '$base/chat/completions';
  }

  /// Build the JSON request body for a non-SSE request.
  ///
  /// If [resolved.requestBodyTemplate] is set, performs `$model` / `$prompt`
  /// variable substitution. Otherwise builds a standard OpenAI-compatible body
  /// with `'stream': false`.
  String _buildNonSSERequestBody(
    ResolvedModelConfig resolved,
    List<Map<String, dynamic>> messages,
  ) {
    if (resolved.requestBodyTemplate != null &&
        resolved.requestBodyTemplate!.isNotEmpty) {
      // Extract the last user message as $prompt
      String prompt = '';
      for (int i = messages.length - 1; i >= 0; i--) {
        if (messages[i]['role'] == 'user') {
          final content = messages[i]['content'];
          prompt = content is String ? content : jsonEncode(content);
          break;
        }
      }
      final filled = resolved.requestBodyTemplate!
          .replaceAll(r'$model', resolved.model)
          .replaceAll(r'$prompt', prompt);
      return filled;
    }

    final requestBody = <String, dynamic>{
      'model': resolved.model,
      'messages': messages,
      'stream': false,
    };
    return jsonEncode(requestBody);
  }

  /// Extract response content from a non-SSE JSON response.
  ///
  /// If [resolved.responseBodyPath] is set, uses [_resolveJsonPath] to extract
  /// the value. Otherwise falls back to standard OpenAI / Claude response shape.
  String _extractResponseContent(
    Map<String, dynamic> json,
    ResolvedModelConfig resolved,
  ) {
    if (resolved.responseBodyPath != null &&
        resolved.responseBodyPath!.isNotEmpty) {
      final value = resolveJsonPath(json, resolved.responseBodyPath!);
      if (value == null) return '';
      final str = value.toString();
      if (_looksLikeImageUrl(str)) {
        return '![Generated Image]($str)';
      }
      return str;
    }

    // Standard OpenAI response shape
    final choices = json['choices'] as List<dynamic>?;
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['message'] as Map<String, dynamic>?;
      if (message != null) {
        final content = message['content'] as String?;
        return content ?? '';
      }
    }

    // Standard Claude response shape
    final content = json['content'] as List<dynamic>?;
    if (content != null && content.isNotEmpty) {
      final textParts = <String>[];
      for (final block in content) {
        if (block is Map<String, dynamic> && block['type'] == 'text') {
          textParts.add(block['text'] as String? ?? '');
        }
      }
      return textParts.join('');
    }

    return '';
  }

  /// Heuristic check whether a string looks like an image URL.
  static bool _looksLikeImageUrl(String value) {
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return false;
    }
    final lower = value.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.svg') ||
        lower.contains('/images/') ||
        lower.contains('image');
  }

  /// Extract tool calls from a non-streaming response (OpenAI format).
  List<LLMToolCallEvent> _extractToolCalls(
    Map<String, dynamic> json,
    ResolvedModelConfig resolved,
  ) {
    final results = <LLMToolCallEvent>[];
    final choices = json['choices'] as List<dynamic>?;
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['message'] as Map<String, dynamic>?;
      if (message != null) {
        final toolCalls = message['tool_calls'] as List<dynamic>?;
        if (toolCalls != null) {
          for (final tc in toolCalls) {
            final tcMap = tc as Map<String, dynamic>;
            final fn = tcMap['function'] as Map<String, dynamic>?;
            if (fn != null) {
              Map<String, dynamic> args;
              try {
                args = jsonDecode(fn['arguments'] as String? ?? '{}')
                    as Map<String, dynamic>;
              } catch (_) {
                args = {};
              }
              results.add(LLMToolCallEvent(
                id: tcMap['id'] as String? ?? '',
                name: fn['name'] as String? ?? '',
                arguments: args,
              ));
            }
          }
        }
      }
    }
    return results;
  }

  // =========================================================================
  // Model routing — resolve effective model config based on attachment modality
  // =========================================================================

  /// Resolve the effective model configuration for a request.
  ///
  /// Priority:
  /// 1. [AgentScenarioModels] explicit mapping.
  /// 2. Main model when its capability tags cover the detected modality.
  /// 3. Main model fallback.
  /// 4. Legacy `llm_*` metadata when `main_model_id` is absent.
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

  // =========================================================================
  // Legacy single-message helpers (used by chat())
  // =========================================================================

  /// OpenAI-compatible streaming chat (covers OpenAI, DeepSeek, Qwen, Kimi,
  /// HunYuan, Ollama, GLM).
  Stream<LLMStreamEvent> _chatOpenAI({
    required String apiBase,
    required String apiKey,
    required String model,
    required String message,
    required String systemPrompt,
    List<Map<String, dynamic>>? history,
    bool enableUITools = true,
    bool includeShepawCli = false,
    List<AttachmentData>? attachments,
  }) async* {
    final effectiveSystemPrompt = enableUITools
        ? '$systemPrompt${UIComponentRegistry.instance.systemPromptSuffix}'
        : systemPrompt;

    final messages = <Map<String, dynamic>>[];
    if (effectiveSystemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': effectiveSystemPrompt});
    }
    if (history != null) {
      messages.addAll(history);
    }

    // Build user message — multimodal if image attachments present
    final imageAttachments = attachments?.where((a) => a.isImage).toList() ?? [];
    final nonImageAttachments = attachments?.where((a) => !a.isImage).toList() ?? [];

    // Prepend non-image attachment descriptions to the text
    String effectiveMessage = message;
    if (nonImageAttachments.isNotEmpty) {
      final descriptions = nonImageAttachments.map((a) => a.textDescription).join('\n');
      effectiveMessage = '$descriptions\n\n$effectiveMessage';
    }

    // If the last message in history is already a user message, merge the
    // current content into it instead of appending a second consecutive user
    // message. Some providers (e.g. GLM/ZhiPu) reject consecutive same-role
    // messages with a 400 error.
    final lastIsUser = messages.isNotEmpty && messages.last['role'] == 'user';

    if (lastIsUser && imageAttachments.isEmpty) {
      // Simple text merge: append current message to the existing user msg.
      final prev = messages.last;
      final prevContent = prev['content'];
      if (prevContent is String) {
        prev['content'] = '$prevContent\n\n$effectiveMessage';
      } else if (prevContent is List) {
        // Previous content is multimodal array — append a text part.
        (prevContent as List).add({'type': 'text', 'text': '\n\n$effectiveMessage'});
      }
    } else if (imageAttachments.isNotEmpty) {
      // OpenAI Vision format: content is an array
      final contentParts = <Map<String, dynamic>>[
        {'type': 'text', 'text': effectiveMessage},
        for (final img in imageAttachments)
          {
            'type': 'image_url',
            'image_url': {'url': 'data:${img.mimeType};base64,${img.base64Data}'},
          },
      ];
      if (lastIsUser) {
        // Merge multimodal content into existing user message.
        final prev = messages.last;
        final prevContent = prev['content'];
        if (prevContent is String) {
          // Convert previous plain text into multimodal array, then append.
          prev['content'] = <Map<String, dynamic>>[
            {'type': 'text', 'text': prevContent},
            ...contentParts,
          ];
        } else if (prevContent is List) {
          (prevContent as List).addAll(contentParts);
        }
      } else {
        messages.add({'role': 'user', 'content': contentParts});
      }
    } else {
      messages.add({'role': 'user', 'content': effectiveMessage});
    }

    final url = apiBase.endsWith('/')
        ? '${apiBase}chat/completions'
        : '$apiBase/chat/completions';

    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
    };
    if (enableUITools) {
      final tools = UIComponentRegistry.instance.openAITools();
      if (includeShepawCli) tools.add(ShepawCLI.instance.openAITool());
      requestBody['tools'] = tools;
    }

    final body = jsonEncode(requestBody);

    final headers = {
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };

    yield* _streamWithMultimodalFallback(
      stream: () => _streamSSEOpenAI(url: url, headers: headers, body: body),
      messages: messages,
      buildRetryStream: (degraded) {
        final retryBody = jsonEncode({...requestBody, 'messages': degraded});
        return _streamSSEOpenAI(url: url, headers: headers, body: retryBody);
      },
    );
  }

  /// Claude (Anthropic) streaming chat.
  Stream<LLMStreamEvent> _chatClaude({
    required String apiBase,
    required String apiKey,
    required String model,
    required String message,
    required String systemPrompt,
    List<Map<String, dynamic>>? history,
    bool enableUITools = true,
    bool includeShepawCli = false,
    List<AttachmentData>? attachments,
  }) async* {
    final effectiveSystemPrompt = enableUITools
        ? '$systemPrompt${UIComponentRegistry.instance.systemPromptSuffix}'
        : systemPrompt;

    final messages = <Map<String, dynamic>>[];
    if (history != null) {
      messages.addAll(history);
    }

    // Build user message — multimodal if image attachments present
    final imageAttachments = attachments?.where((a) => a.isImage).toList() ?? [];
    final nonImageAttachments = attachments?.where((a) => !a.isImage).toList() ?? [];

    // Prepend non-image attachment descriptions to the text
    String effectiveMessage = message;
    if (nonImageAttachments.isNotEmpty) {
      final descriptions = nonImageAttachments.map((a) => a.textDescription).join('\n');
      effectiveMessage = '$descriptions\n\n$effectiveMessage';
    }

    if (imageAttachments.isNotEmpty) {
      // Claude multimodal format: content is an array of blocks
      final contentParts = <Map<String, dynamic>>[
        for (final img in imageAttachments)
          {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': img.mimeType,
              'data': img.base64Data,
            },
          },
        {'type': 'text', 'text': effectiveMessage},
      ];
      messages.add({'role': 'user', 'content': contentParts});
    } else {
      messages.add({'role': 'user', 'content': effectiveMessage});
    }

    final url = apiBase.endsWith('/')
        ? '${apiBase}messages'
        : '$apiBase/messages';

    final requestBody = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'max_tokens': 4096,
    };
    if (effectiveSystemPrompt.isNotEmpty) {
      requestBody['system'] = effectiveSystemPrompt;
    }
    if (enableUITools) {
      final tools = UIComponentRegistry.instance.claudeTools();
      if (includeShepawCli) tools.add(ShepawCLI.instance.claudeTool());
      requestBody['tools'] = tools;
    }

    final body = jsonEncode(requestBody);

    final headers = {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
      'anthropic-version': '2023-06-01',
    };

    yield* _streamWithMultimodalFallback(
      stream: () => _streamSSEClaude(url: url, headers: headers, body: body),
      messages: messages,
      buildRetryStream: (degraded) {
        final retryBody = jsonEncode({...requestBody, 'messages': degraded});
        return _streamSSEClaude(url: url, headers: headers, body: retryBody);
      },
    );
  }

  // ---------------------------------------------------------------------------
  // SSE helpers
  // ---------------------------------------------------------------------------

  /// Open an SSE POST connection and return the [HttpClientResponse].
  Future<(HttpClient, HttpClientResponse)> _openSSE({
    required String url,
    required Map<String, String> headers,
    required String body,
  }) async {
    final uri = Uri.parse(url);
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;

    try {
      final request = await client.postUrl(uri);
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.add(utf8.encode(body));
      final response = await request.close();

      if (response.statusCode != 200) {
        final errorBody = await response.transform(utf8.decoder).join();
        client.close();
        LoggerService().error('API error ${response.statusCode} from $url — body length: ${body.length}', tag: 'LocalLLM');
        throw Exception(
            'LLM API error (${response.statusCode}): $errorBody');
      }

      return (client, response);
    } catch (e) {
      client.close();
      if (e is Exception &&
          e.toString().contains('LLM API error')) {
        rethrow;
      }
      throw Exception('Failed to connect to LLM API: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // OpenAI SSE parser
  // ---------------------------------------------------------------------------

  /// Parse an OpenAI-compatible SSE stream, yielding [LLMStreamEvent]s.
  ///
  /// Text tokens arrive in `choices[0].delta.content`.
  /// Tool calls arrive in `choices[0].delta.tool_calls` and are accumulated
  /// across multiple chunks until `finish_reason == "tool_calls"`.
  ///
  /// A final [LLMDoneEvent] is yielded with the stop reason and accumulated
  /// assistant content (text + tool_calls) for multi-round history.
  Stream<LLMStreamEvent> _streamSSEOpenAI({
    required String url,
    required Map<String, String> headers,
    required String body,
  }) async* {
    final (client, response) = await _openSSE(
      url: url,
      headers: headers,
      body: body,
    );
    _registerClient(client);

    try {
      // Accumulators for streaming tool_calls:
      // index -> {id, name, argumentsBuffer}
      final Map<int, _OpenAIToolCallAccumulator> toolAccumulators = {};

      // Accumulate text content for the raw assistant message
      final textBuffer = StringBuffer();
      // Accumulate reasoning_content (Kimi thinking mode) for the raw assistant message
      final reasoningBuffer = StringBuffer();
      String? lastFinishReason;

      String buffer = '';
      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        while (buffer.contains('\n')) {
          final newlineIndex = buffer.indexOf('\n');
          final line = buffer.substring(0, newlineIndex).trim();
          buffer = buffer.substring(newlineIndex + 1);

          if (line.isEmpty) continue;
          if (!line.startsWith('data:')) continue;

          final data = line.substring(5).trim();
          if (data == '[DONE]') break;

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final choices = json['choices'] as List<dynamic>?;
            if (choices == null || choices.isEmpty) continue;

            final choice = choices[0] as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>?;
            final finishReason = choice['finish_reason'] as String?;

            if (finishReason != null) {
              lastFinishReason = finishReason;
            }

            if (delta != null) {
              // Reasoning content (Kimi thinking mode) — must be captured and
              // echoed back in assistant messages that also contain tool_calls,
              // otherwise Kimi returns 400: "reasoning_content is missing".
              final reasoningContent = delta['reasoning_content'] as String?;
              if (reasoningContent != null && reasoningContent.isNotEmpty) {
                reasoningBuffer.write(reasoningContent);
              }

              // Text content
              final content = delta['content'] as String?;
              if (content != null && content.isNotEmpty) {
                textBuffer.write(content);
                yield LLMTextEvent(content);
              }

              // Tool calls (accumulated across chunks)
              final toolCalls = delta['tool_calls'] as List<dynamic>?;
              if (toolCalls != null) {
                for (final tc in toolCalls) {
                  final tcMap = tc as Map<String, dynamic>;
                  final index = tcMap['index'] as int? ?? 0;
                  final acc = toolAccumulators.putIfAbsent(
                    index,
                    () => _OpenAIToolCallAccumulator(),
                  );

                  if (tcMap.containsKey('id')) {
                    acc.id = tcMap['id'] as String? ?? '';
                  }
                  final fn = tcMap['function'] as Map<String, dynamic>?;
                  if (fn != null) {
                    if (fn.containsKey('name')) {
                      acc.name = fn['name'] as String? ?? '';
                    }
                    if (fn.containsKey('arguments')) {
                      acc.argumentsBuffer.write(fn['arguments'] as String? ?? '');
                    }
                  }
                }
              }
            }

            // When finish_reason is "tool_calls", emit accumulated tool calls
            if (finishReason == 'tool_calls') {
              for (final acc in toolAccumulators.values) {
                if (acc.name.isNotEmpty) {
                  Map<String, dynamic> args;
                  try {
                    args = jsonDecode(acc.argumentsBuffer.toString())
                        as Map<String, dynamic>;
                  } catch (_) {
                    args = {};
                  }
                  yield LLMToolCallEvent(
                    id: acc.id,
                    name: acc.name,
                    arguments: args,
                  );
                }
              }
              // Don't clear — we need them for the raw assistant message
            }
          } catch (_) {
            // Skip malformed JSON lines
          }
        }
      }

      // If there are un-emitted tool calls (e.g. some providers don't set
      // finish_reason to "tool_calls"), emit them now.
      if (lastFinishReason != 'tool_calls') {
        for (final acc in toolAccumulators.values) {
          if (acc.name.isNotEmpty) {
            Map<String, dynamic> args;
            try {
              args = jsonDecode(acc.argumentsBuffer.toString())
                  as Map<String, dynamic>;
            } catch (_) {
              args = {};
            }
            yield LLMToolCallEvent(
              id: acc.id,
              name: acc.name,
              arguments: args,
            );
          }
        }
      }

      // Build the raw assistant message for multi-round history
      final rawAssistant = <String, dynamic>{
        'role': 'assistant',
      };
      final textStr = textBuffer.toString();
      if (textStr.isNotEmpty) {
        rawAssistant['content'] = textStr;
      }
      // Include reasoning_content when present so Kimi's thinking mode doesn't
      // reject the replayed assistant message with a 400 error.
      final reasoningStr = reasoningBuffer.toString();
      if (reasoningStr.isNotEmpty) {
        rawAssistant['reasoning_content'] = reasoningStr;
      }
      if (toolAccumulators.isNotEmpty) {
        rawAssistant['tool_calls'] = toolAccumulators.entries.map((e) {
          final acc = e.value;
          return <String, dynamic>{
            'id': acc.id,
            'type': 'function',
            'function': {
              'name': acc.name,
              'arguments': acc.argumentsBuffer.toString(),
            },
          };
        }).toList();
      }

      yield LLMDoneEvent(
        stopReason: lastFinishReason ?? 'stop',
        rawAssistantMessage: rawAssistant,
      );
    } on HttpException catch (_) {
      // Force-closed by abort() — silently stop yielding.
    } on SocketException catch (_) {
      // Force-closed by abort() — silently stop yielding.
    } finally {
      _unregisterClient(client);
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Claude SSE parser
  // ---------------------------------------------------------------------------

  /// Parse a Claude (Anthropic) SSE stream, yielding [LLMStreamEvent]s.
  ///
  /// Text tokens: `content_block_delta` with `delta.type == "text_delta"`.
  /// Tool use:
  ///   - `content_block_start` with `content_block.type == "tool_use"` → capture id/name
  ///   - `content_block_delta` with `delta.type == "input_json_delta"` → accumulate JSON
  ///   - `content_block_stop` → parse & emit [LLMToolCallEvent]
  ///
  /// A final [LLMDoneEvent] is yielded with the stop reason and accumulated
  /// assistant content blocks for multi-round history.
  Stream<LLMStreamEvent> _streamSSEClaude({
    required String url,
    required Map<String, String> headers,
    required String body,
  }) async* {
    final (client, response) = await _openSSE(
      url: url,
      headers: headers,
      body: body,
    );
    _registerClient(client);

    try {
      // Current tool_use block being accumulated
      String? currentToolId;
      String? currentToolName;
      final currentToolArgs = StringBuffer();

      // Accumulated content blocks for the raw assistant message
      final contentBlocks = <Map<String, dynamic>>[];
      final textBuffer = StringBuffer();
      String? stopReason;

      String buffer = '';
      String? currentEventType;

      await for (final chunk in response.transform(utf8.decoder)) {
        buffer += chunk;
        while (buffer.contains('\n')) {
          final newlineIndex = buffer.indexOf('\n');
          final line = buffer.substring(0, newlineIndex).trim();
          buffer = buffer.substring(newlineIndex + 1);

          if (line.isEmpty) continue;

          // Track SSE event type
          if (line.startsWith('event:')) {
            currentEventType = line.substring(6).trim();
            continue;
          }

          if (!line.startsWith('data:')) continue;

          final data = line.substring(5).trim();
          if (data == '[DONE]') break;

          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final type = json['type'] as String? ?? currentEventType ?? '';

            switch (type) {
              case 'message_start':
                // Capture stop_reason if present at message level
                final message = json['message'] as Map<String, dynamic>?;
                if (message != null) {
                  stopReason = message['stop_reason'] as String?;
                }
                break;

              case 'content_block_start':
                final contentBlock =
                    json['content_block'] as Map<String, dynamic>?;
                if (contentBlock != null &&
                    contentBlock['type'] == 'tool_use') {
                  currentToolId = contentBlock['id'] as String? ?? '';
                  currentToolName = contentBlock['name'] as String? ?? '';
                  currentToolArgs.clear();
                }
                break;

              case 'content_block_delta':
                final delta = json['delta'] as Map<String, dynamic>?;
                if (delta == null) break;
                final deltaType = delta['type'] as String?;

                if (deltaType == 'text_delta') {
                  final text = delta['text'] as String?;
                  if (text != null && text.isNotEmpty) {
                    textBuffer.write(text);
                    yield LLMTextEvent(text);
                  }
                } else if (deltaType == 'input_json_delta') {
                  final partial = delta['partial_json'] as String?;
                  if (partial != null) {
                    currentToolArgs.write(partial);
                  }
                }
                break;

              case 'content_block_stop':
                if (currentToolName != null && currentToolName.isNotEmpty) {
                  Map<String, dynamic> args;
                  try {
                    args = jsonDecode(currentToolArgs.toString())
                        as Map<String, dynamic>;
                  } catch (_) {
                    args = {};
                  }
                  yield LLMToolCallEvent(
                    id: currentToolId ?? '',
                    name: currentToolName,
                    arguments: args,
                  );
                  // Save to content blocks for raw assistant message
                  contentBlocks.add({
                    'type': 'tool_use',
                    'id': currentToolId ?? '',
                    'name': currentToolName,
                    'input': args,
                  });
                  currentToolId = null;
                  currentToolName = null;
                  currentToolArgs.clear();
                } else if (textBuffer.isNotEmpty) {
                  // Finalize text block
                  contentBlocks.add({
                    'type': 'text',
                    'text': textBuffer.toString(),
                  });
                }
                break;

              case 'message_delta':
                final delta = json['delta'] as Map<String, dynamic>?;
                if (delta != null) {
                  stopReason = delta['stop_reason'] as String? ?? stopReason;
                }
                break;
            }
          } catch (_) {
            // Skip malformed JSON lines
          }
        }
      }

      // Ensure text content is in content blocks even if no content_block_stop
      if (contentBlocks.isEmpty && textBuffer.isNotEmpty) {
        contentBlocks.add({
          'type': 'text',
          'text': textBuffer.toString(),
        });
      }

      yield LLMDoneEvent(
        stopReason: stopReason ?? 'end_turn',
        rawAssistantMessage: {
          'role': 'assistant',
          'content': contentBlocks,
        },
      );
    } on HttpException catch (_) {
      // Force-closed by abort() — silently stop yielding.
    } on SocketException catch (_) {
      // Force-closed by abort() — silently stop yielding.
    } finally {
      _unregisterClient(client);
      client.close();
    }
  }

  // =========================================================================
  // Multimodal degradation helpers
  // =========================================================================

  /// Wraps a streaming LLM call with automatic multimodal degradation fallback.
  ///
  /// Uses `await for` (not `yield*`) so that errors thrown during stream
  /// creation (e.g. HTTP 400 from `_openSSE`) are caught here instead of
  /// propagating directly to the outer stream listener.
  ///
  /// **Proactive history degradation**: Before making the first API call,
  /// multimodal content in historical messages (all messages except the last
  /// user message) is replaced with `[Image]` text placeholders. This avoids
  /// unnecessary API failures and repeated warnings when images only exist in
  /// older conversation history.
  ///
  /// If the API still returns a 4xx error (because the *current* user message
  /// contains images the model cannot handle), the remaining images are
  /// degraded and the request is retried once with a warning.
  Stream<LLMStreamEvent> _streamWithMultimodalFallback({
    required Stream<LLMStreamEvent> Function() stream,
    required List<Map<String, dynamic>> messages,
    required Stream<LLMStreamEvent> Function(List<Map<String, dynamic>> degraded)
        buildRetryStream,
  }) async* {
    // Proactively degrade multimodal content in historical messages so that
    // models that don't support images won't fail on old history.
    final historyDegraded = _degradeHistoryMultimodal(messages);

    // Check if any historical message was actually degraded by comparing
    // object identity (unchanged messages keep their original reference).
    bool historyWasDegraded = false;
    for (int i = 0; i < messages.length; i++) {
      if (!identical(historyDegraded[i], messages[i])) {
        historyWasDegraded = true;
        break;
      }
    }

    // Use the degraded messages for the initial call if history had images.
    final Stream<LLMStreamEvent> Function() effectiveStream;
    if (historyWasDegraded) {
      effectiveStream = () => buildRetryStream(historyDegraded);
    } else {
      effectiveStream = stream;
    }

    try {
      await for (final event in effectiveStream()) {
        yield event;
      }
    } catch (e) {
      if (_lastUserMessageHasMultimodal(historyDegraded) &&
          e.toString().contains('LLM API error (4')) {
        yield LLMTextEvent(
            '> ⚠️ 当前模型不支持图片识别，已自动忽略图片内容，回复可能不够准确。\n\n');
        final degraded = _degradeMultimodalMessages(historyDegraded);
        await for (final event in buildRetryStream(degraded)) {
          yield event;
        }
      } else {
        rethrow;
      }
    }
  }

  /// Check whether the last user message contains multimodal content.
  static bool _lastUserMessageHasMultimodal(
      List<Map<String, dynamic>> messages) {
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        return messages[i]['content'] is List;
      }
    }
    return false;
  }

  /// Degrade a single message's multimodal content to plain text.
  static Map<String, dynamic> _degradeMessage(Map<String, dynamic> msg) {
    final content = msg['content'];
    if (content is! List) return msg;

    final textParts = <String>[];
    for (final part in content) {
      if (part is Map<String, dynamic>) {
        if (part['type'] == 'text') {
          textParts.add(part['text'] as String? ?? '');
        } else if (part['type'] == 'image_url' || part['type'] == 'image') {
          textParts.add('[Image]');
        }
      }
    }
    return {...msg, 'content': textParts.join('\n')};
  }

  /// Replace all multimodal content blocks in [messages] with plain text.
  ///
  /// - OpenAI `{type: 'image_url', ...}` → `[Image]`
  /// - Claude `{type: 'image', ...}` → `[Image]`
  /// - `{type: 'text', text: ...}` parts are preserved
  /// - Messages whose `content` is already a `String` are returned as-is.
  static List<Map<String, dynamic>> _degradeMultimodalMessages(
      List<Map<String, dynamic>> messages) {
    return messages.map(_degradeMessage).toList();
  }

  /// Degrade multimodal content in historical messages only, preserving the
  /// last user message's multimodal content (e.g. images in the current turn).
  ///
  /// This prevents repeated "model does not support images" warnings when
  /// images only exist in older history messages.
  static List<Map<String, dynamic>> _degradeHistoryMultimodal(
      List<Map<String, dynamic>> messages) {
    // Find the index of the last user message.
    int lastUserIdx = -1;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i]['role'] == 'user') {
        lastUserIdx = i;
        break;
      }
    }

    return messages.asMap().entries.map((entry) {
      if (entry.key == lastUserIdx) return entry.value;
      return _degradeMessage(entry.value);
    }).toList();
  }
}

/// Accumulator for an in-progress OpenAI tool call being streamed.
class _OpenAIToolCallAccumulator {
  String id = '';
  String name = '';
  final StringBuffer argumentsBuffer = StringBuffer();
}

/// Model Registry — globally configured model definitions.
///
/// Models are stored in SharedPreferences and can be enabled per-agent.
/// When used as tool models, the main LLM calls them via tool/function calling.
/// They can also be referenced for multi-modal routing or as general endpoints.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/model_definition.dart';
import '../models/model_routing_config.dart';
import 'logger_service.dart';

const _prefsKey = 'tool_model_definitions';

/// Central registry for tool model definitions.
class ModelRegistry {
  ModelRegistry._();
  static final ModelRegistry instance = ModelRegistry._();

  List<ModelDefinition> _definitions = [];

  /// All currently loaded tool model definitions.
  List<ModelDefinition> get definitions =>
      List.unmodifiable(_definitions);

  /// All tool model tool names.
  Set<String> get allToolNames =>
      _definitions.map((d) => d.toolName).toSet();

  // ---------------------------------------------------------------------------
  // Initialization & Persistence
  // ---------------------------------------------------------------------------

  /// Load tool model definitions from SharedPreferences. Call once at startup.
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _definitions = list
            .map((e) =>
                ModelDefinition.fromJson(e as Map<String, dynamic>))
            .where((d) => !d.isEmpty)
            .toList();
      } catch (e) {
        LoggerService().error('Failed to load definitions', tag: 'ModelRegistry', error: e);
        _definitions = [];
      }
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final json = jsonEncode(_definitions.map((d) => d.toJson()).toList());
    await prefs.setString(_prefsKey, json);
  }

  // ---------------------------------------------------------------------------
  // CRUD
  // ---------------------------------------------------------------------------

  /// Add a new tool model definition. Returns the created definition.
  Future<ModelDefinition> add({
    required String displayName,
    required String description,
    required ModelRouteConfig route,
    Set<ModelType> modelTypes = const {},
  }) async {
    final id = const Uuid().v4();
    final toolName = ModelDefinition.deriveToolName(displayName);
    final def = ModelDefinition(
      id: id,
      toolName: toolName,
      displayName: displayName,
      description: description,
      route: route,
      modelTypes: modelTypes,
    );
    _definitions.add(def);
    await _persist();
    return def;
  }

  /// Update an existing tool model definition by [id].
  Future<void> update(ModelDefinition updated) async {
    final idx = _definitions.indexWhere((d) => d.id == updated.id);
    if (idx == -1) return;
    _definitions[idx] = updated;
    await _persist();
  }

  /// Delete a tool model definition by [id].
  Future<void> delete(String id) async {
    _definitions.removeWhere((d) => d.id == id);
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // Lookups
  // ---------------------------------------------------------------------------

  /// Whether [name] is a registered tool model tool.
  bool isToolModelTool(String name) =>
      _definitions.any((d) => d.toolName == name);

  /// Lookup a definition by tool name, or null.
  ModelDefinition? getDefinition(String toolName) {
    for (final d in _definitions) {
      if (d.toolName == toolName) return d;
    }
    return null;
  }

  /// Lookup a definition by id, or null.
  ModelDefinition? getById(String id) {
    for (final d in _definitions) {
      if (d.id == id) return d;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // LLM tool formats
  // ---------------------------------------------------------------------------

  /// Returns tool models in OpenAI function-calling format.
  List<Map<String, dynamic>> openAITools({
    required Set<String> enabledToolModels,
    Map<String, String> scenarioOverrides = const {},
  }) {
    return _filtered(enabledToolModels)
        .map((d) {
              final baseDesc = scenarioOverrides[d.toolName]?.isNotEmpty == true
                  ? scenarioOverrides[d.toolName]!
                  : d.description.isNotEmpty
                      ? d.description
                      : d.displayName;
              final typeTag = d.modelTypes.isNotEmpty
                  ? '[${d.modelTypes.map((t) => t.name).join(',')}] '
                  : '';
              final desc = '$typeTag$baseDesc';
              return <String, dynamic>{
              'type': 'function',
              'function': {
                'name': d.toolName,
                'description': desc,
                'parameters': {
                  'type': 'object',
                  'properties': {
                    'prompt': {
                      'type': 'string',
                      'description':
                          'The prompt or instruction to send to the ${d.displayName} model.',
                    },
                  },
                  'required': ['prompt'],
                },
              },
            };})
        .toList();
  }

  /// Returns tool models in Claude (Anthropic) format.
  List<Map<String, dynamic>> claudeTools({
    required Set<String> enabledToolModels,
    Map<String, String> scenarioOverrides = const {},
  }) {
    return _filtered(enabledToolModels)
        .map((d) {
              final baseDesc = scenarioOverrides[d.toolName]?.isNotEmpty == true
                  ? scenarioOverrides[d.toolName]!
                  : d.description.isNotEmpty
                      ? d.description
                      : d.displayName;
              final typeTag = d.modelTypes.isNotEmpty
                  ? '[${d.modelTypes.map((t) => t.name).join(',')}] '
                  : '';
              final desc = '$typeTag$baseDesc';
              return <String, dynamic>{
              'name': d.toolName,
              'description': desc,
              'input_schema': {
                'type': 'object',
                'properties': {
                  'prompt': {
                    'type': 'string',
                    'description':
                        'The prompt or instruction to send to the ${d.displayName} model.',
                  },
                },
                'required': ['prompt'],
              },
            };})
        .toList();
  }

  /// System prompt suffix describing available tool models.
  String systemPromptSuffix(
    Set<String> enabledToolModels, {
    Map<String, String> scenarioOverrides = const {},
  }) {
    final filtered = _filtered(enabledToolModels);
    if (filtered.isEmpty) return '';
    final lines = filtered.map((d) {
      final desc = scenarioOverrides[d.toolName]?.isNotEmpty == true
          ? scenarioOverrides[d.toolName]!
          : d.description.isNotEmpty
              ? d.description
              : d.displayName;
      final typesSuffix = d.modelTypes.isNotEmpty
          ? ' (types: ${d.modelTypes.map((t) => t.name).join(', ')})'
          : '';
      return '- ${d.toolName}: $desc$typesSuffix';
    }).join('\n');
    return '''

You also have access to tool model tools. Each tool model routes your prompt to a specialised model and returns the result.
When your task matches one of these tools, call it with the appropriate prompt.
Available tool models:
$lines''';
  }

  // ---------------------------------------------------------------------------
  // Execution
  // ---------------------------------------------------------------------------

  /// Execute a tool model call. Sends the prompt to the configured endpoint
  /// and returns the result string.
  Future<String> executeToolModel(
    String toolName,
    Map<String, dynamic> arguments,
  ) async {
    final def = getDefinition(toolName);
    if (def == null) return 'Error: tool model "$toolName" not found.';

    final route = def.route;
    final prompt = arguments['prompt'] as String? ?? '';

    // Resolve configuration
    final model = route.model ?? '';
    final apiBase = route.apiBase ?? '';
    final apiKey = route.apiKey ?? '';
    final apiPath = route.apiPath;
    final requestBodyTemplate = route.requestBodyTemplate;
    final responseBodyPath = route.responseBodyPath;

    if (apiBase.isEmpty || model.isEmpty) {
      return 'Error: tool model "$toolName" is not fully configured (missing apiBase or model).';
    }

    // Build URL
    final base =
        apiBase.endsWith('/') ? apiBase.substring(0, apiBase.length - 1) : apiBase;
    final String url;
    if (apiPath != null && apiPath.isNotEmpty) {
      final path = apiPath.startsWith('/') ? apiPath : '/$apiPath';
      url = '$base$path';
    } else {
      url = '$base/chat/completions';
    }

    // Build request body
    final String body;
    if (requestBodyTemplate != null && requestBodyTemplate.isNotEmpty) {
      body = requestBodyTemplate
          .replaceAll(r'$model', model)
          .replaceAll(r'$prompt', prompt);
    } else {
      body = jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'stream': false,
      });
    }

    // Build headers
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };

    // Execute HTTP request
    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      final request = await client.postUrl(Uri.parse(url));
      for (final entry in headers.entries) {
        request.headers.set(entry.key, entry.value);
      }
      request.add(utf8.encode(body));
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        return 'Error: tool model API returned status ${response.statusCode}: $responseBody';
      }

      final json = jsonDecode(responseBody) as Map<String, dynamic>;

      // Extract content
      if (responseBodyPath != null && responseBodyPath.isNotEmpty) {
        final value = resolveJsonPath(json, responseBodyPath);
        if (value == null) return responseBody;
        return value.toString();
      }

      // Standard OpenAI-compatible response
      try {
        final choices = json['choices'] as List<dynamic>?;
        if (choices != null && choices.isNotEmpty) {
          final message = choices[0]['message'] as Map<String, dynamic>?;
          if (message != null) {
            return message['content'] as String? ?? responseBody;
          }
        }
      } catch (_) {}

      return responseBody;
    } catch (e) {
      return 'Error calling tool model "$toolName": $e';
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Iterable<ModelDefinition> _filtered(Set<String> enabledToolModels) {
    return _definitions
        .where((d) => enabledToolModels.contains(d.toolName));
  }
}

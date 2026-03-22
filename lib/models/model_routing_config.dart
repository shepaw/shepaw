import 'remote_agent.dart' show repairUtf16Garbled;

String? _repairNullable(String? s) =>
    s != null ? repairUtf16Garbled(s) : null;

/// Modality types for model routing.
enum ModalityType {
  text,
  image,
  audio,
  video;

  String get label {
    switch (this) {
      case ModalityType.text:
        return 'Text';
      case ModalityType.image:
        return 'Image';
      case ModalityType.audio:
        return 'Audio';
      case ModalityType.video:
        return 'Video';
    }
  }

  String get icon {
    switch (this) {
      case ModalityType.text:
        return '\u{1F4DD}'; // memo
      case ModalityType.image:
        return '\u{1F5BC}'; // framed picture
      case ModalityType.audio:
        return '\u{1F3B5}'; // musical note
      case ModalityType.video:
        return '\u{1F3AC}'; // clapper board
    }
  }
}

/// Model configuration for a single modality route.
///
/// All fields are nullable. When null, the value is inherited from the
/// agent's fallback (top-level) LLM configuration.
class ModelRouteConfig {
  final String? provider;
  final String? model;
  final String? apiBase;
  final String? apiKey;

  /// Whether to use streaming (SSE). `null` inherits default (true),
  /// `false` forces non-SSE plain JSON request/response.
  final bool? stream;

  /// Override the API endpoint path (e.g. `/images/generations`).
  final String? apiPath;

  /// JSON template with `$model` / `$prompt` variable substitution.
  final String? requestBodyTemplate;

  /// Dot-bracket JSON path to extract content from the response
  /// (e.g. `data[0].url`, `choices[0].message.content`).
  final String? responseBodyPath;

  const ModelRouteConfig({
    this.provider,
    this.model,
    this.apiBase,
    this.apiKey,
    this.stream,
    this.apiPath,
    this.requestBodyTemplate,
    this.responseBodyPath,
  });

  bool get isEmpty =>
      (provider == null || provider!.isEmpty) &&
      (model == null || model!.isEmpty) &&
      (apiBase == null || apiBase!.isEmpty) &&
      (apiKey == null || apiKey!.isEmpty) &&
      stream == null &&
      (apiPath == null || apiPath!.isEmpty) &&
      (requestBodyTemplate == null || requestBodyTemplate!.isEmpty) &&
      (responseBodyPath == null || responseBodyPath!.isEmpty);

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    if (provider != null && provider!.isNotEmpty) map['provider'] = provider;
    if (model != null && model!.isNotEmpty) map['model'] = model;
    if (apiBase != null && apiBase!.isNotEmpty) map['api_base'] = apiBase;
    if (apiKey != null && apiKey!.isNotEmpty) map['api_key'] = apiKey;
    if (stream != null) map['stream'] = stream;
    if (apiPath != null && apiPath!.isNotEmpty) map['api_path'] = apiPath;
    if (requestBodyTemplate != null && requestBodyTemplate!.isNotEmpty) {
      map['request_body_template'] = requestBodyTemplate;
    }
    if (responseBodyPath != null && responseBodyPath!.isNotEmpty) {
      map['response_body_path'] = responseBodyPath;
    }
    return map;
  }

  factory ModelRouteConfig.fromJson(Map<String, dynamic> json) {
    return ModelRouteConfig(
      provider: json['provider'] as String?,
      model: json['model'] as String?,
      apiBase: json['api_base'] as String?,
      apiKey: _repairNullable(json['api_key'] as String?),
      stream: json['stream'] as bool?,
      apiPath: json['api_path'] as String?,
      requestBodyTemplate: json['request_body_template'] as String?,
      responseBodyPath: json['response_body_path'] as String?,
    );
  }
}

/// Resolved model configuration with all fields guaranteed non-null.
class ResolvedModelConfig {
  final String providerType;
  final String model;
  final String apiBase;
  final String apiKey;

  /// Whether to use streaming (SSE). Defaults to `true`.
  final bool stream;

  /// Override the API endpoint path (e.g. `/images/generations`).
  final String? apiPath;

  /// JSON template with `$model` / `$prompt` variable substitution.
  final String? requestBodyTemplate;

  /// Dot-bracket JSON path to extract content from the response.
  final String? responseBodyPath;

  const ResolvedModelConfig({
    required this.providerType,
    required this.model,
    required this.apiBase,
    required this.apiKey,
    this.stream = true,
    this.apiPath,
    this.requestBodyTemplate,
    this.responseBodyPath,
  });
}

/// A user-defined custom modality for intent-based routing.
///
/// Custom modalities (e.g. `image_gen`, `tts`, `video_gen`) allow routing
/// pure-text prompts to specialised models based on a small-model intent
/// classifier that runs **only when custom modalities are configured**.
class CustomModality {
  final String key;           // e.g. "image_gen", "tts", "video_gen"
  final String label;         // Display name: "图片生成", "语音合成"
  final String description;   // Used in classifier prompt
  final ModelRouteConfig route;

  const CustomModality({
    required this.key,
    required this.label,
    required this.description,
    required this.route,
  });

  bool get isEmpty => key.isEmpty || route.isEmpty;

  Map<String, dynamic> toJson() => {
    'key': key,
    'label': label,
    'description': description,
    'route': route.toJson(),
  };

  factory CustomModality.fromJson(Map<String, dynamic> json) => CustomModality(
    key: json['key'] as String? ?? '',
    label: json['label'] as String? ?? '',
    description: json['description'] as String? ?? '',
    route: ModelRouteConfig.fromJson(json['route'] as Map<String, dynamic>? ?? {}),
  );
}

/// Multi-modal model routing configuration.
///
/// Stored in `RemoteAgent.metadata['model_routing']`. Each modality can
/// optionally override the agent's default (fallback) LLM configuration.
class ModelRoutingConfig {
  final Map<ModalityType, ModelRouteConfig> routes;
  final List<CustomModality> customModalities;

  const ModelRoutingConfig({
    this.routes = const {},
    this.customModalities = const [],
  });

  bool get isEmpty =>
      (routes.isEmpty || routes.values.every((r) => r.isEmpty)) &&
      customModalities.every((m) => m.isEmpty);

  /// Whether intent classification is needed (non-empty custom modalities exist).
  bool get needsIntentClassification =>
      customModalities.any((m) => !m.isEmpty);

  /// Resolve the effective model config for [modality], falling back to the
  /// agent's top-level LLM config for any field not set in the route.
  ResolvedModelConfig resolve(
    ModalityType modality, {
    required String fallbackProvider,
    required String fallbackModel,
    required String fallbackApiBase,
    required String fallbackApiKey,
  }) {
    final route = routes[modality];
    return ResolvedModelConfig(
      providerType: (route?.provider != null && route!.provider!.isNotEmpty)
          ? route.provider!
          : fallbackProvider,
      model: (route?.model != null && route!.model!.isNotEmpty)
          ? route.model!
          : fallbackModel,
      apiBase: (route?.apiBase != null && route!.apiBase!.isNotEmpty)
          ? route.apiBase!
          : fallbackApiBase,
      apiKey: (route?.apiKey != null && route!.apiKey!.isNotEmpty)
          ? route.apiKey!
          : fallbackApiKey,
      stream: route?.stream ?? true,
      apiPath: route?.apiPath,
      requestBodyTemplate: route?.requestBodyTemplate,
      responseBodyPath: route?.responseBodyPath,
    );
  }

  /// Resolve a custom modality by [key], with fallbacks.
  ResolvedModelConfig resolveCustom(
    String key, {
    required String fallbackProvider,
    required String fallbackModel,
    required String fallbackApiBase,
    required String fallbackApiKey,
  }) {
    final custom = customModalities.firstWhere(
      (m) => m.key == key,
      orElse: () => const CustomModality(
        key: '', label: '', description: '', route: ModelRouteConfig()),
    );
    final route = custom.route;
    return ResolvedModelConfig(
      providerType: (route.provider?.isNotEmpty == true)
          ? route.provider!
          : fallbackProvider,
      model: (route.model?.isNotEmpty == true) ? route.model! : fallbackModel,
      apiBase: (route.apiBase?.isNotEmpty == true)
          ? route.apiBase!
          : fallbackApiBase,
      apiKey: (route.apiKey?.isNotEmpty == true)
          ? route.apiKey!
          : fallbackApiKey,
      stream: route.stream ?? true,
      apiPath: route.apiPath,
      requestBodyTemplate: route.requestBodyTemplate,
      responseBodyPath: route.responseBodyPath,
    );
  }

  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{};
    for (final entry in routes.entries) {
      if (!entry.value.isEmpty) {
        map[entry.key.name] = entry.value.toJson();
      }
    }
    final nonEmpty = customModalities.where((m) => !m.isEmpty).toList();
    if (nonEmpty.isNotEmpty) {
      map['custom_modalities'] = nonEmpty.map((m) => m.toJson()).toList();
    }
    return map;
  }

  factory ModelRoutingConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) {
      return const ModelRoutingConfig();
    }
    final routes = <ModalityType, ModelRouteConfig>{};
    for (final type in ModalityType.values) {
      final routeJson = json[type.name] as Map<String, dynamic>?;
      if (routeJson != null) {
        final config = ModelRouteConfig.fromJson(routeJson);
        if (!config.isEmpty) {
          routes[type] = config;
        }
      }
    }
    final customList = json['custom_modalities'] as List<dynamic>?;
    final customModalities = customList
        ?.map((e) => CustomModality.fromJson(e as Map<String, dynamic>))
        .toList() ?? const [];
    return ModelRoutingConfig(
      routes: routes,
      customModalities: customModalities,
    );
  }

  /// Detect the modality of a message based on attachment semantic types.
  ///
  /// Priority: video > audio > image > text.
  static ModalityType detectModality(List<String> attachmentSemanticTypes) {
    if (attachmentSemanticTypes.isEmpty) return ModalityType.text;
    for (final t in attachmentSemanticTypes) {
      if (t == 'video') return ModalityType.video;
    }
    for (final t in attachmentSemanticTypes) {
      if (t == 'audio') return ModalityType.audio;
    }
    for (final t in attachmentSemanticTypes) {
      if (t == 'image') return ModalityType.image;
    }
    return ModalityType.text;
  }
}

/// Resolve a dot-bracket JSON path like `data[0].url` or
/// `choices[0].message.content` against a parsed JSON object.
///
/// Returns `null` if the path cannot be resolved (missing key, index out of
/// bounds, etc.).
dynamic resolveJsonPath(dynamic json, String path) {
  dynamic current = json;
  final segments = <String>[];
  final raw = path.split('.');
  for (final part in raw) {
    final bracketIdx = part.indexOf('[');
    if (bracketIdx == -1) {
      segments.add(part);
    } else {
      if (bracketIdx > 0) {
        segments.add(part.substring(0, bracketIdx));
      }
      final re = RegExp(r'\[(\d+)\]');
      for (final m in re.allMatches(part)) {
        segments.add('[${m.group(1)}]');
      }
    }
  }

  for (final seg in segments) {
    if (current == null) return null;
    if (seg.startsWith('[') && seg.endsWith(']')) {
      final index = int.tryParse(seg.substring(1, seg.length - 1));
      if (index == null) return null;
      if (current is List && index < current.length) {
        current = current[index];
      } else {
        return null;
      }
    } else {
      if (current is Map<String, dynamic>) {
        current = current[seg];
      } else {
        return null;
      }
    }
  }
  return current;
}

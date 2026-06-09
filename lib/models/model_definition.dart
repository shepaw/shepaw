import 'model_routing_config.dart';

/// The functional type(s) of a model.
///
/// A single model may support multiple types (e.g. a multimodal model can
/// handle both [text] and [imageUnderstanding]).
enum ModelType {
  /// General-purpose text chat / completion.
  text,

  /// Understands images provided as input.
  imageUnderstanding,

  /// Understands audio provided as input.
  audioUnderstanding,

  /// Understands video provided as input.
  videoUnderstanding,

  /// Generates images from a text prompt.
  imageGeneration,

  /// Synthesises speech (text-to-speech).
  tts,

  /// Generates video from a text or image prompt.
  videoGeneration;

  String toJson() => name;

  static ModelType? fromJson(String? value) {
    if (value == null) return null;
    for (final t in ModelType.values) {
      if (t.name == value) return t;
    }
    return null;
  }
}

/// Maps [ModalityType] to the [ModelType] required to handle it.
extension ModalityRequiredModelType on ModalityType {
  ModelType get requiredModelType {
    switch (this) {
      case ModalityType.text:
        return ModelType.text;
      case ModalityType.image:
        return ModelType.imageUnderstanding;
      case ModalityType.audio:
        return ModelType.audioUnderstanding;
      case ModalityType.video:
        return ModelType.videoUnderstanding;
      case ModalityType.imageGeneration:
        return ModelType.imageGeneration;
      case ModalityType.tts:
        return ModelType.tts;
      case ModalityType.videoGeneration:
        return ModelType.videoGeneration;
    }
  }

  bool get isInputScenario => kInputScenarioModalities.contains(this);

  bool get isGenerationScenario => kGenerationScenarioModalities.contains(this);
}

/// Model types used when routing user attachments (scenario table).
const Set<ModelType> kInputScenarioModelTypes = {
  ModelType.text,
  ModelType.imageUnderstanding,
  ModelType.audioUnderstanding,
  ModelType.videoUnderstanding,
};

/// Model types the main LLM can delegate to via tool calling.
const Set<ModelType> kDelegatableModelTypes = {
  ModelType.imageGeneration,
  ModelType.tts,
  ModelType.videoGeneration,
};

/// Input-understanding scenarios (user attachments).
const List<ModalityType> kInputScenarioModalities = [
  ModalityType.image,
  ModalityType.audio,
  ModalityType.video,
];

/// Generation / delegation scenarios (LLM tool calls).
const List<ModalityType> kGenerationScenarioModalities = [
  ModalityType.imageGeneration,
  ModalityType.tts,
  ModalityType.videoGeneration,
];

/// All per-scenario overrides shown in agent model config (excludes text).
const List<ModalityType> kConfigurableScenarioModalities = [
  ...kInputScenarioModalities,
  ...kGenerationScenarioModalities,
];

/// @deprecated Use [kInputScenarioModalities].
const List<ModalityType> kAttachmentModalities = kInputScenarioModalities;

extension ModelDefinitionCapability on ModelDefinition {
  bool supportsScenario(ModalityType modality) =>
      modelTypes.contains(modality.requiredModelType);

  bool get isDelegatable =>
      modelTypes.any(kDelegatableModelTypes.contains);
}

extension ModelDefinitionListFilters on Iterable<ModelDefinition> {
  List<ModelDefinition> forScenario(
    ModalityType modality, {
    String? includeId,
  }) {
    final matches =
        where((d) => d.supportsScenario(modality)).toList();
    if (includeId == null) return matches;
    if (matches.any((d) => d.id == includeId)) return matches;
    final extra = where((d) => d.id == includeId);
    return [...matches, ...extra];
  }

  List<ModelDefinition> forDelegation() =>
      where((d) => d.isDelegatable).toList();
}

bool mainModelCoversModality(ModelDefinition? main, ModalityType modality) {
  if (main == null) return false;
  return main.modelTypes.contains(modality.requiredModelType);
}

/// A globally configured model definition that can be reused across agents.
///
/// Models can serve multiple purposes:
/// - **Tool model**: Exposed to the main LLM as a callable tool for delegated
///   tasks (image generation, TTS, etc.). The LLM decides when to invoke it.
/// - **Scenario model**: Referenced in an agent's scenario table for input
///   routing (text/image/audio/video attachments).
/// - **Conversation model**: A general-purpose LLM endpoint (main model).
///
/// Definitions are stored globally (SharedPreferences) and enabled per-agent.
class ModelDefinition {
  /// Unique identifier (UUID).
  final String id;

  /// Tool name used in function-calling (prefixed with `tool_model_`).
  final String toolName;

  /// Human-readable display name shown in the UI.
  final String displayName;

  /// Description exposed to the LLM so it knows when to call this tool.
  /// Optional — when empty and used as a tool model, the display name is used
  /// as a fallback description.
  final String description;

  /// Model route configuration (provider, model, apiBase, apiKey, stream,
  /// apiPath, requestBodyTemplate, responseBodyPath).
  final ModelRouteConfig route;

  /// The functional type(s) this model supports (may be empty for untagged
  /// legacy models).
  final Set<ModelType> modelTypes;

  const ModelDefinition({
    required this.id,
    required this.toolName,
    required this.displayName,
    required this.description,
    required this.route,
    this.modelTypes = const {},
  });

  bool get isEmpty =>
      toolName.isEmpty || displayName.isEmpty || route.isEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tool_name': toolName,
        'display_name': displayName,
        'description': description,
        'route': route.toJson(),
        'model_types': modelTypes.map((t) => t.toJson()).toList(),
      };

  factory ModelDefinition.fromJson(Map<String, dynamic> json) {
    final rawTypes = json['model_types'] as List<dynamic>? ?? [];
    final types = rawTypes
        .map((e) => ModelType.fromJson(e as String?))
        .whereType<ModelType>()
        .toSet();
    return ModelDefinition(
      id: json['id'] as String? ?? '',
      toolName: json['tool_name'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      route: ModelRouteConfig.fromJson(
          json['route'] as Map<String, dynamic>? ?? {}),
      modelTypes: types,
    );
  }

  ModelDefinition copyWith({
    String? id,
    String? toolName,
    String? displayName,
    String? description,
    ModelRouteConfig? route,
    Set<ModelType>? modelTypes,
  }) {
    return ModelDefinition(
      id: id ?? this.id,
      toolName: toolName ?? this.toolName,
      displayName: displayName ?? this.displayName,
      description: description ?? this.description,
      route: route ?? this.route,
      modelTypes: modelTypes ?? this.modelTypes,
    );
  }

  /// Derive a valid tool name from a display name.
  static String deriveToolName(String displayName) {
    final sanitized = displayName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return 'tool_model_$sanitized';
  }
}

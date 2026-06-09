import 'model_definition.dart';
import 'model_routing_config.dart';
import '../services/model_registry.dart';

/// Per-agent scenario → model mapping stored in `metadata['scenario_models']`.
///
/// Each [ModalityType] may optionally reference a global [ModelDefinition] id.
/// Absent keys inherit [main_model_id] at resolve time.
class AgentScenarioModels {
  final Map<ModalityType, String> modelIds;

  const AgentScenarioModels({this.modelIds = const {}});

  bool get isEmpty => modelIds.isEmpty;

  int get configuredCount => modelIds.length;

  String? modelIdFor(ModalityType modality) => modelIds[modality];

  Map<String, dynamic> toJson() => {
        for (final entry in modelIds.entries) entry.key.name: entry.value,
      };

  factory AgentScenarioModels.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return const AgentScenarioModels();
    final ids = <ModalityType, String>{};
    for (final type in ModalityType.values) {
      final id = json[type.name] as String?;
      if (id != null && id.isNotEmpty) ids[type] = id;
    }
    return AgentScenarioModels(modelIds: ids);
  }

  AgentScenarioModels withOverride(ModalityType modality, String? modelId) {
    final next = Map<ModalityType, String>.from(modelIds);
    if (modelId == null || modelId.isEmpty) {
      next.remove(modality);
    } else {
      next[modality] = modelId;
    }
    return AgentScenarioModels(modelIds: next);
  }

  /// Merge generation-scenario models into [manualEnabled] tool names.
  Set<String> mergeGenerationToolModels(
    Set<String> manualEnabled,
    ModelRegistry registry,
  ) {
    final result = Set<String>.from(manualEnabled);
    for (final modality in kGenerationScenarioModalities) {
      final id = modelIds[modality];
      if (id == null || id.isEmpty) continue;
      final def = registry.getById(id);
      if (def != null) result.add(def.toolName);
    }
    return result;
  }

  /// Derive [enabled_tool_models] solely from generation scenario mappings.
  Set<String> enabledGenerationToolModels(ModelRegistry registry) =>
      mergeGenerationToolModels({}, registry);

  /// Load scenario models for the agent editor, migrating legacy config when needed.
  static AgentScenarioModels loadForEditing({
    required Map<String, dynamic> metadata,
    required Iterable<String> enabledToolModels,
    required ModelRoutingConfig modelRouting,
    required List<ModelDefinition> definitions,
  }) {
    var models = AgentScenarioModels.fromJson(
      metadata['scenario_models'] as Map<String, dynamic>?,
    );
    models = migrateFromEnabledDelegationToolModels(
      enabledToolModels,
      definitions,
      models,
    );
    if (!models.isEmpty) return models;

    final fromRouting =
        migrateFromLegacyModelRouting(modelRouting, definitions);
    if (!fromRouting.isEmpty) {
      return migrateFromEnabledDelegationToolModels(
        enabledToolModels,
        definitions,
        fromRouting,
      );
    }

    final fromInput =
        migrateFromEnabledInputToolModels(enabledToolModels, definitions);
    return migrateFromEnabledDelegationToolModels(
      enabledToolModels,
      definitions,
      fromInput,
    );
  }

  /// Migrate legacy enabled delegation tool models into generation scenario keys.
  static AgentScenarioModels migrateFromEnabledDelegationToolModels(
    Iterable<String> enabledToolNames,
    List<ModelDefinition> definitions,
    AgentScenarioModels existing,
  ) {
    const delegationMap = {
      ModelType.imageGeneration: ModalityType.imageGeneration,
      ModelType.tts: ModalityType.tts,
      ModelType.videoGeneration: ModalityType.videoGeneration,
    };
    final ids = Map<ModalityType, String>.from(existing.modelIds);
    for (final toolName in enabledToolNames) {
      ModelDefinition? def;
      for (final d in definitions) {
        if (d.toolName == toolName) {
          def = d;
          break;
        }
      }
      if (def == null) continue;
      for (final entry in delegationMap.entries) {
        if (!def.modelTypes.contains(entry.key)) continue;
        final modality = entry.value;
        if (ids.containsKey(modality)) continue;
        ids[modality] = def.id;
        break;
      }
    }
    return AgentScenarioModels(modelIds: ids);
  }

  /// Migrate legacy setups that routed attachments via enabled input-understanding tool models.
  static AgentScenarioModels migrateFromEnabledInputToolModels(
    Iterable<String> enabledToolNames,
    List<ModelDefinition> definitions,
  ) {
    const inputModalities = {
      ModalityType.image: ModelType.imageUnderstanding,
      ModalityType.audio: ModelType.audioUnderstanding,
      ModalityType.video: ModelType.videoUnderstanding,
    };
    final ids = <ModalityType, String>{};
    for (final entry in inputModalities.entries) {
      for (final toolName in enabledToolNames) {
        ModelDefinition? def;
        for (final d in definitions) {
          if (d.toolName == toolName) {
            def = d;
            break;
          }
        }
        if (def == null) continue;
        if (def.modelTypes.contains(entry.value)) {
          ids[entry.key] = def.id;
          break;
        }
      }
    }
    return AgentScenarioModels(modelIds: ids);
  }

  /// Best-effort migration from legacy inline [ModelRoutingConfig] routes.
  static AgentScenarioModels migrateFromLegacyModelRouting(
    ModelRoutingConfig routing,
    List<ModelDefinition> definitions,
  ) {
    final ids = <ModalityType, String>{};
    for (final entry in routing.routes.entries) {
      final route = entry.value;
      if (route.isEmpty) continue;
      final modelName = route.model;
      if (modelName == null || modelName.isEmpty) continue;

      ModelDefinition? match;
      for (final def in definitions) {
        if (def.route.model != modelName) continue;
        final routeBase = route.apiBase ?? '';
        final defBase = def.route.apiBase ?? '';
        if (routeBase.isEmpty || defBase.isEmpty || routeBase == defBase) {
          match = def;
          break;
        }
      }
      if (match != null) ids[entry.key] = match.id;
    }
    return AgentScenarioModels(modelIds: ids);
  }

  /// Resolve the [ModelDefinition] for [modality], or null to fall through.
  ModelDefinition? resolveDefinition(
    ModalityType modality, {
    required String? mainModelId,
    required ModelRegistry registry,
  }) {
    final explicitId = modelIds[modality];
    if (explicitId != null && explicitId.isNotEmpty) {
      return registry.getById(explicitId);
    }
    if (modality == ModalityType.text &&
        mainModelId != null &&
        mainModelId.isNotEmpty) {
      return registry.getById(mainModelId);
    }
    return null;
  }

  /// Describe effective model resolution per modality (CLI / diagnostics).
  static Map<String, dynamic> describeResolvedScenarios({
    required Map<String, dynamic> metadata,
    required Iterable<String> enabledToolModels,
    required ModelRoutingConfig legacyRouting,
    required List<ModelDefinition> definitions,
    required ModelRegistry registry,
    bool Function(ModalityType modality)? supportsModality,
  }) {
    final scenarios = loadForEditing(
      metadata: metadata,
      enabledToolModels: enabledToolModels,
      modelRouting: legacyRouting,
      definitions: definitions,
    );
    final mainModelId = metadata['main_model_id'] as String?;
    final mainDef =
        mainModelId != null ? registry.getById(mainModelId) : null;
    final resolved = <String, dynamic>{};
    final support = <String, bool>{};

    for (final type in ModalityType.values) {
      if (type == ModalityType.text) {
        support[type.name] = true;
        continue;
      }

      final supported = supportsModality?.call(type) ??
          (type.isGenerationScenario
              ? (scenarios.modelIdFor(type) != null &&
                  registry.getById(scenarios.modelIdFor(type)!) != null)
              : (scenarios.modelIdFor(type) != null &&
                      registry.getById(scenarios.modelIdFor(type)!) != null) ||
                  (mainDef != null &&
                      mainDef.modelTypes.contains(type.requiredModelType)));
      support[type.name] = supported;

      ModelDefinition? def = scenarios.resolveDefinition(
        type,
        mainModelId: mainModelId,
        registry: registry,
      );
      var source = scenarios.modelIdFor(type) != null ? 'scenario' : 'inherit_main';

      if (def == null && !type.isGenerationScenario && mainDef != null) {
        def = mainDef;
        source = mainDef.modelTypes.contains(type.requiredModelType)
            ? 'main_model_tag'
            : 'main_model_fallback';
      }

      if (def == null) continue;

      resolved[type.name] = {
        'model_id': def.id,
        'display_name': def.displayName,
        'model': def.route.model,
        'api_base': def.route.apiBase,
        'source': source,
        'supported': supported,
      };
    }

    return {
      'modality_support': support,
      'effective_routes': resolved,
    };
  }

  /// Build a [ResolvedModelConfig] from a registry [ModelDefinition].
  static ResolvedModelConfig configFromDefinition(ModelDefinition def) {
    final r = def.route;
    return ResolvedModelConfig(
      providerType: (r.provider != null && r.provider!.isNotEmpty)
          ? r.provider!
          : 'openai',
      model: r.model ?? '',
      apiBase: r.apiBase ?? '',
      apiKey: r.apiKey != null && r.apiKey!.isNotEmpty ? r.apiKey! : '',
      stream: r.stream ?? true,
      apiPath: r.apiPath,
      requestBodyTemplate: r.requestBodyTemplate,
      responseBodyPath: r.responseBodyPath,
    );
  }
}

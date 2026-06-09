import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent_scenario_models.dart';
import 'package:shepaw/models/model_definition.dart';
import 'package:shepaw/models/model_routing_config.dart';
import 'package:shepaw/services/model_registry.dart';

void main() {
  group('AgentScenarioModels', () {
    test('toJson/fromJson roundtrip includes generation scenarios', () {
      const models = AgentScenarioModels(modelIds: {
        ModalityType.image: 'img-id',
        ModalityType.imageGeneration: 'gen-id',
        ModalityType.tts: 'tts-id',
      });
      final restored = AgentScenarioModels.fromJson(models.toJson());
      expect(restored.modelIdFor(ModalityType.imageGeneration), 'gen-id');
      expect(restored.modelIdFor(ModalityType.tts), 'tts-id');
    });

    test('toJson/fromJson roundtrip', () {
      const models = AgentScenarioModels(modelIds: {
        ModalityType.image: 'img-id',
        ModalityType.audio: 'aud-id',
      });
      final restored = AgentScenarioModels.fromJson(models.toJson());
      expect(restored.modelIdFor(ModalityType.image), 'img-id');
      expect(restored.modelIdFor(ModalityType.text), isNull);
    });

    test('withOverride removes key when set to null', () {
      const models = AgentScenarioModels(modelIds: {
        ModalityType.image: 'img-id',
      });
      final cleared = models.withOverride(ModalityType.image, null);
      expect(cleared.isEmpty, isTrue);
    });

    test('migrateFromLegacyModelRouting matches by model name', () {
      const defs = [
        ModelDefinition(
          id: 'def-llava',
          toolName: 'tool_model_llava',
          displayName: 'LLaVA',
          description: '',
          route: ModelRouteConfig(model: 'llava', apiBase: 'http://localhost:11434/v1'),
          modelTypes: {ModelType.imageUnderstanding},
        ),
        ModelDefinition(
          id: 'def-gemma',
          toolName: 'tool_model_gemma',
          displayName: 'Gemma',
          description: '',
          route: ModelRouteConfig(model: 'gemma4'),
          modelTypes: {ModelType.text},
        ),
      ];
      final routing = ModelRoutingConfig(routes: {
        ModalityType.image: const ModelRouteConfig(model: 'llava'),
      });
      final migrated =
          AgentScenarioModels.migrateFromLegacyModelRouting(routing, defs);
      expect(migrated.modelIdFor(ModalityType.image), 'def-llava');
    });

    test('configFromDefinition builds resolved config', () {
      const def = ModelDefinition(
        id: 'x',
        toolName: 'tool_model_x',
        displayName: 'X',
        description: '',
        route: ModelRouteConfig(
          provider: 'openai',
          model: 'gpt-4o',
          apiBase: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
        ),
      );
      final resolved = AgentScenarioModels.configFromDefinition(def);
      expect(resolved.model, 'gpt-4o');
      expect(resolved.providerType, 'openai');
      expect(resolved.apiKey, 'sk-test');
    });

    test('migrateFromEnabledInputToolModels maps input-understanding tool models', () {
      const defs = [
        ModelDefinition(
          id: 'def-llava',
          toolName: 'tool_model_llava',
          displayName: 'LLaVA',
          description: '',
          route: ModelRouteConfig(model: 'llava'),
          modelTypes: {ModelType.imageUnderstanding},
        ),
        ModelDefinition(
          id: 'def-sd',
          toolName: 'tool_model_sd',
          displayName: 'SD',
          description: '',
          route: ModelRouteConfig(model: 'sd-xl'),
          modelTypes: {ModelType.imageGeneration},
        ),
      ];
      final migrated = AgentScenarioModels.migrateFromEnabledInputToolModels(
        ['tool_model_llava', 'tool_model_sd'],
        defs,
      );
      expect(migrated.modelIdFor(ModalityType.image), 'def-llava');
      expect(migrated.modelIdFor(ModalityType.text), isNull);
    });

    test('migrateFromEnabledDelegationToolModels maps generation tool models', () {
      const defs = [
        ModelDefinition(
          id: 'def-sd',
          toolName: 'tool_model_sd',
          displayName: 'SD',
          description: '',
          route: ModelRouteConfig(model: 'sd-xl'),
          modelTypes: {ModelType.imageGeneration},
        ),
      ];
      const existing = AgentScenarioModels();
      final migrated = AgentScenarioModels.migrateFromEnabledDelegationToolModels(
        ['tool_model_sd'],
        defs,
        existing,
      );
      expect(migrated.modelIdFor(ModalityType.imageGeneration), 'def-sd');
    });

    test('mergeGenerationToolModels preserves manual tools when no generation configured', () {
      const models = AgentScenarioModels();
      final merged = models.mergeGenerationToolModels(
        {'tool_model_a'},
        ModelRegistry.instance,
      );
      expect(merged, {'tool_model_a'});
    });

    test('loadForEditing prefers scenario_models over tool model migration', () {
      const defs = [
        ModelDefinition(
          id: 'def-llava',
          toolName: 'tool_model_llava',
          displayName: 'LLaVA',
          description: '',
          route: ModelRouteConfig(model: 'llava'),
          modelTypes: {ModelType.imageUnderstanding},
        ),
      ];
      final loaded = AgentScenarioModels.loadForEditing(
        metadata: {
          'scenario_models': {'image': 'other-id'},
        },
        enabledToolModels: {'tool_model_llava'},
        modelRouting: const ModelRoutingConfig(),
        definitions: defs,
      );
      expect(loaded.modelIdFor(ModalityType.image), 'other-id');
    });
  });
}

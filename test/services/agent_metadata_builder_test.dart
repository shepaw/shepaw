import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/model_definition.dart';
import 'package:shepaw/models/model_routing_config.dart';
import 'package:shepaw/services/agent_metadata_builder.dart';

ModelDefinition _def({
  required String id,
  String? provider,
  String? model,
  String? apiBase,
}) {
  return ModelDefinition(
    id: id,
    toolName: 'tool_model_$id',
    displayName: 'Model $id',
    description: '',
    route: ModelRouteConfig(
      provider: provider,
      model: model ?? 'gpt-$id',
      apiBase: apiBase ?? 'https://api.example.com/v1',
    ),
  );
}

/// 用一个只认识 [known] 里 id 的表代替 ModelRegistry。
ModelLookup _lookup(List<ModelDefinition> known) {
  return (id) {
    for (final def in known) {
      if (def.id == id) return def;
    }
    return null;
  };
}

void main() {
  group('buildLlmMetadata', () {
    test('解析到定义：写入 id + provider，并清掉 legacy llm_* 字段', () {
      final metadata = <String, dynamic>{
        'llm_model': 'old-model',
        'llm_api_base': 'https://old.example.com',
        'llm_api_key': 'sk-old',
      };

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: 'A',
        lookupModel: _lookup([_def(id: 'A', provider: 'anthropic')]),
      );

      expect(result.state, MainModelState.resolved);
      expect(result.danglingRef, isNull);
      expect(metadata['main_model_id'], 'A');
      expect(metadata['llm_provider'], 'anthropic');
      expect(metadata.containsKey('llm_model'), isFalse);
      expect(metadata.containsKey('llm_api_base'), isFalse);
      expect(metadata.containsKey('llm_api_key'), isFalse);
    });

    test('route.provider 为空时回退到 openai', () {
      final metadata = <String, dynamic>{};

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: 'A',
        lookupModel: _lookup([_def(id: 'A', provider: '')]),
      );

      expect(result.state, MainModelState.resolved);
      expect(metadata['llm_provider'], 'openai');
    });

    test('未选中但存储的 id 仍可解析：回落到它并补回 provider', () {
      final metadata = <String, dynamic>{'main_model_id': 'A'};

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup([_def(id: 'A', provider: 'anthropic')]),
      );

      expect(result.state, MainModelState.resolved);
      expect(metadata['main_model_id'], 'A');
      expect(metadata['llm_provider'], 'anthropic');
    });

    // 本次修复的核心断言。
    test('悬空：定义被删后 llm_provider 与 main_model_id 都必须保留', () {
      final metadata = <String, dynamic>{
        'main_model_id': 'deleted',
        'llm_provider': 'anthropic',
        'enabled_skills': ['a'],
      };

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.dangling);
      expect(result.danglingRef, 'deleted');
      // llm_provider 是 RemoteAgent.isLocal 的唯一判据 —— 丢了这个，
      // 本地 agent 会被静默改写成远端 ACP agent。
      expect(metadata['llm_provider'], 'anthropic');
      // 保留 id 让模型被重新添加后能自动恢复。
      expect(metadata['main_model_id'], 'deleted');
      expect(metadata['enabled_skills'], ['a']);
    });

    test('悬空：只有 legacy llm_provider（无 main_model_id）同样保留', () {
      final metadata = <String, dynamic>{
        'llm_provider': 'openai',
        'llm_model': 'legacy-model',
        'llm_api_base': 'https://legacy.example.com',
      };

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.dangling);
      expect(result.danglingRef, 'legacy-model');
      expect(metadata['llm_provider'], 'openai');
    });

    test('悬空：选中的 id 已不在 registry 时也走保留分支', () {
      final metadata = <String, dynamic>{'main_model_id': 'deleted'};

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: 'deleted',
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.dangling);
      expect(result.danglingRef, 'deleted');
    });

    test('本来就没有主模型：清空主模型键', () {
      final metadata = <String, dynamic>{
        'llm_model': 'stale',
        'llm_api_base': 'https://stale.example.com',
        'llm_api_key': 'sk-stale',
      };

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.unset);
      expect(result.danglingRef, isNull);
      expect(metadata.containsKey('llm_provider'), isFalse);
      expect(metadata.containsKey('main_model_id'), isFalse);
      expect(metadata.containsKey('llm_model'), isFalse);
      expect(metadata.containsKey('llm_api_base'), isFalse);
      expect(metadata.containsKey('llm_api_key'), isFalse);
    });

    test('She：没有任何模型痕迹时是 no-op', () {
      final metadata = <String, dynamic>{
        'is_she': true,
        'system_prompt': '',
      };

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.unset);
      expect(metadata, {'is_she': true, 'system_prompt': ''});
    });

    test('main_model_id 为空串不算配置过', () {
      final metadata = <String, dynamic>{'main_model_id': ''};

      final result = buildLlmMetadata(
        metadata,
        selectedMainModelId: null,
        lookupModel: _lookup(const []),
      );

      expect(result.state, MainModelState.unset);
      expect(metadata.containsKey('main_model_id'), isFalse);
    });
  });
}

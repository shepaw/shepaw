import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/model_definition.dart';
import 'package:shepaw/models/model_routing_config.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/model_usage_service.dart';

ModelDefinition _def({
  required String id,
  String toolName = '',
  Set<ModelType> modelTypes = const {},
}) {
  return ModelDefinition(
    id: id,
    toolName: toolName.isEmpty ? 'tool_model_$id' : toolName,
    displayName: 'Model $id',
    description: '',
    route: const ModelRouteConfig(provider: 'openai', model: 'm'),
    modelTypes: modelTypes,
  );
}

RemoteAgent _agent({
  required String id,
  required String name,
  String? mainModelId,
  Map<String, dynamic>? scenarioModels,
  List<String>? enabledToolModels,
}) {
  return RemoteAgent(
    id: id,
    name: name,
    token: '',
    endpoint: '',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.http,
    createdAt: 0,
    updatedAt: 0,
    metadata: {
      if (mainModelId != null) 'main_model_id': mainModelId,
      if (scenarioModels != null) 'scenario_models': scenarioModels,
      if (enabledToolModels != null) 'enabled_tool_models': enabledToolModels,
    },
  );
}

void main() {
  group('ModelUsageService.build', () {
    test('主模型引用按 defId 归集', () {
      final usage = ModelUsageService.build([
        _agent(id: 'a1', name: 'Alice', mainModelId: 'm1'),
        _agent(id: 'a2', name: 'Bob', mainModelId: 'm1'),
        _agent(id: 'a3', name: 'Carol', mainModelId: 'm2'),
      ]);

      expect(usage.keys.toSet(), {'m1', 'm2'});
      expect(usage['m1']!['main'], [
        {'id': 'a1', 'name': 'Alice'},
        {'id': 'a2', 'name': 'Bob'},
      ]);
      expect(usage['m2']!['main'], [
        {'id': 'a3', 'name': 'Carol'},
      ]);
      expect(usage['m2']!['scenario'], isEmpty);
    });

    test('场景模型按 modality.name 归集', () {
      final usage = ModelUsageService.build([
        _agent(
          id: 'a1',
          name: 'Alice',
          mainModelId: 'm1',
          scenarioModels: {'image': 'm2', 'tts': 'm3'},
        ),
      ]);

      expect(usage['m2']!['scenario'], {
        'image': [
          {'id': 'a1', 'name': 'Alice'},
        ],
      });
      expect(usage['m3']!['scenario'], {
        'tts': [
          {'id': 'a1', 'name': 'Alice'},
        ],
      });
      // 主模型那一栏不该被场景引用污染。
      expect(usage['m2']!['main'], isEmpty);
    });

    test('未配置任何模型的 agent 不产生条目', () {
      final usage = ModelUsageService.build([
        _agent(id: 'a1', name: 'She'),
      ]);

      expect(usage, isEmpty);
    });

    test('enabled_tool_models 中可委派的定义按 tool_model 记账', () {
      final delegatable = _def(
        id: 'm9',
        toolName: 'tool_model_image',
        modelTypes: {ModelType.imageGeneration},
      );
      final plain = _def(id: 'm8', toolName: 'tool_model_text');

      final usage = ModelUsageService.build(
        [
          _agent(
            id: 'a1',
            name: 'Alice',
            enabledToolModels: ['tool_model_image', 'tool_model_text', 'missing'],
          ),
        ],
        getDefinition: (toolName) => switch (toolName) {
          'tool_model_image' => delegatable,
          'tool_model_text' => plain,
          _ => null,
        },
      );

      expect(usage.keys.toSet(), {'m9'});
      expect(usage['m9']!['scenario'], {
        'tool_model': [
          {'id': 'a1', 'name': 'Alice'},
        ],
      });
    });

    test('空 main_model_id 不计入引用', () {
      final usage = ModelUsageService.build([
        _agent(id: 'a1', name: 'Alice', mainModelId: ''),
      ]);

      expect(usage, isEmpty);
    });
  });

  group('ModelUsageService.referencedAgentNames', () {
    test('合并主模型与全部场景引用并去重', () {
      final usage = ModelUsageService.build([
        // Alice：m2 同时作为图片场景和 TTS 场景模型（同一 agent 去重一次）。
        _agent(
          id: 'a1',
          name: 'Alice',
          mainModelId: 'm1',
          scenarioModels: {'image': 'm2', 'tts': 'm2'},
        ),
        _agent(id: 'a2', name: 'Bob', mainModelId: 'm2'),
      ]);

      // 主模型引用排在场景引用之前。
      expect(ModelUsageService.referencedAgentNames(usage['m2']!), ['Bob', 'Alice']);
      expect(ModelUsageService.referencedAgentNames(usage['m1']!), ['Alice']);
    });

    test('空引用返回空列表', () {
      expect(
        ModelUsageService.referencedAgentNames(const {
          'main': <dynamic>[],
          'scenario': <String, dynamic>{},
        }),
        isEmpty,
      );
    });
  });
}

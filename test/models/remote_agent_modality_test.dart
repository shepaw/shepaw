import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/model_routing_config.dart';
import 'package:shepaw/models/remote_agent.dart';

void main() {
  group('RemoteAgent.supportsModality', () {
    RemoteAgent localAgent(Map<String, dynamic> metadata) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return RemoteAgent(
        id: 'local-1',
        name: 'Local',
        token: 't',
        endpoint: '',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        metadata: {'llm_provider': 'openai', ...metadata},
        createdAt: now,
        updatedAt: now,
      );
    }

    test('text is always supported', () {
      final agent = localAgent({});
      expect(agent.supportsModality(ModalityType.text), isTrue);
    });

    test('image not supported with only Ollama metadata and no explicit config', () {
      final agent = localAgent({
        'llm_api_base': 'http://localhost:11434/v1',
        'llm_model': 'gemma4',
      });
      expect(agent.supportsModality(ModalityType.image), isFalse);
    });

    test('image not supported with only legacy model_routing metadata', () {
      final agent = localAgent({
        'model_routing': {
          'image': {'model': 'llava'},
        },
      });
      expect(agent.supportsModality(ModalityType.image), isFalse);
    });

    test('image not supported when scenario_models id missing from registry', () {
      final agent = localAgent({
        'scenario_models': {'image': 'missing-id'},
      });
      expect(agent.supportsModality(ModalityType.image), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/host_she_turn.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  RemoteAgent agent({
    required String id,
    required ProtocolType protocol,
    Map<String, dynamic>? metadata,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return RemoteAgent(
      id: id,
      name: 'She',
      token: '',
      endpoint: '',
      protocol: protocol,
      connectionType: ConnectionType.websocket,
      createdAt: now,
      updatedAt: now,
      metadata: metadata ?? const {},
    );
  }

  test('主机惜宝走储物袋回合，引擎实例走 agent_chat', () {
    final she = agent(
      id: SheService.sheId,
      protocol: ProtocolType.peer,
      metadata: const {
        'is_she': true,
        'remote_agent_id': SheService.sheId,
        'llm_provider': 'openai',
      },
    );
    final cursor = agent(
      id: 'cursor-1',
      protocol: ProtocolType.peer,
      metadata: const {
        'remote_agent_id': 'cursor-1',
        'engine': 'cursor',
      },
    );
    final local = agent(
      id: 'local-1',
      protocol: ProtocolType.acp,
      metadata: const {'llm_provider': 'openai'},
    );

    expect(relaysHostSheTurn(she), isTrue);
    expect(hostSheTurnAgentId(she), SheService.sheId);
    expect(relaysHostSheTurn(cursor), isFalse);
    expect(relaysHostSheTurn(local), isFalse);
    expect(she.isLocal, isFalse);
    expect(local.isLocal, isTrue);
  });

  test('行 id 不是惜宝 id 时，用远端 id', () {
    final she = agent(
      id: 'card-1',
      protocol: ProtocolType.peer,
      metadata: const {'remote_agent_id': SheService.sheId},
    );
    expect(relaysHostSheTurn(she), isTrue);
    expect(hostSheTurnAgentId(she), SheService.sheId);
  });

  test('主模型地址从选中的定义里取出', () {
    final endpoint = hostSheEndpointFromMetadata(
      const {'main_model_id': 'm1'},
      lookup: (id) => HostSheEndpoint(
        model: 'gpt-4o',
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'sk-$id',
      ),
    );
    expect(endpoint?.model, 'gpt-4o');
    expect(endpoint?.baseUrl, 'https://api.example.com/v1');
    expect(endpoint?.isReady, isTrue);
    expect(
      hostSheEndpointFromMetadata(const {}, lookup: (_) => null),
      isNull,
    );
  });
}

import 'dart:io';

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
        'has_main_model': true,
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
    expect(chatUsesRegistryMainModel(she), isTrue);
    expect(chatUsesRegistryMainModel(local), isTrue);
    expect(chatUsesRegistryMainModel(cursor), isFalse);
  });

  test('只有电脑把本机名单补进空的储物袋', () {
    expect(sheCatalogMigratesLocalRegistry(phone: false), isTrue);
    expect(sheCatalogMigratesLocalRegistry(phone: true), isFalse);
  });

  test('储物袋里已经有的模型不再上传', () {
    final missing = sheCatalogMissingFromDevice(
      local: [
        (
          displayName: '书房',
          model: 'gpt-4o',
          baseUrl: 'https://api.example/v1',
          apiKey: 'sk-a',
        ),
        (
          displayName: '备用',
          model: 'gpt-4o-mini',
          baseUrl: 'https://api.example/v1',
          apiKey: 'sk-b',
        ),
        (
          displayName: '没地址',
          model: 'local-only',
          baseUrl: '',
          apiKey: '',
        ),
      ],
      remote: [
        (model: 'gpt-4o', baseUrl: 'https://api.example/v1'),
      ],
    );
    expect(missing, hasLength(1));
    expect(missing.single.displayName, '备用');
    expect(missing.single.model, 'gpt-4o-mini');
    expect(
      sheCatalogContains(
        remote: const [(model: 'gpt-4o', baseUrl: 'https://api.example/v1')],
        model: 'gpt-4o',
        baseUrl: 'https://api.example/v1',
      ),
      isTrue,
    );
  });

  test('储物袋里只有模型 id 时，用电脑上的名字', () {
    final names = sheCatalogNamesFromDevice(
      local: [
        (
          displayName: 'tokenhub-ds-v4.1-flash',
          model: 'deepseek/deepseek-flash',
          baseUrl: 'https://tokenhub.example/v1',
          apiKey: 'sk',
        ),
        (
          displayName: '书房',
          model: 'gpt-4o',
          baseUrl: 'https://api.example/v1',
          apiKey: 'sk-a',
        ),
      ],
      remote: [
        (
          displayName: 'deepseek/deepseek-flash',
          model: 'deepseek/deepseek-flash',
          baseUrl: 'https://tokenhub.example/v1',
        ),
        (
          displayName: '已有名字',
          model: 'gpt-4o',
          baseUrl: 'https://api.example/v1',
        ),
      ],
    );
    expect(names, hasLength(1));
    expect(names.single.displayName, 'tokenhub-ds-v4.1-flash');
    expect(names.single.model, 'deepseek/deepseek-flash');
  });

  test('惜宝的模型菜单永远不走本机注册表', () {
    expect(
      composerUsesRegistryMenu(hostShe: true, hasPeerModels: true),
      isFalse,
    );
    expect(
      composerUsesRegistryMenu(hostShe: true, hasPeerModels: false),
      isFalse,
    );
    // 别的 peer agent：上游给了名单就用上游的，没给才退回本机注册表。
    expect(
      composerUsesRegistryMenu(hostShe: false, hasPeerModels: true),
      isFalse,
    );
    expect(
      composerUsesRegistryMenu(hostShe: false, hasPeerModels: false),
      isTrue,
    );
  });

  test('Cursor 模型菜单不走注册表下拉', () {
    expect(
      composerOpensCursorModelPanel(
        useRegistry: false,
        hasModelOptions: true,
      ),
      isTrue,
    );
    expect(
      composerOpensCursorModelPanel(
        useRegistry: false,
        hasModelOptions: false,
      ),
      isFalse,
    );
    expect(
      composerOpensCursorModelPanel(
        useRegistry: true,
        hasModelOptions: true,
      ),
      isFalse,
    );
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

  test('主机惜宝看 Hub 回来的 has_main_model', () {
    final she = agent(
      id: SheService.sheId,
      protocol: ProtocolType.peer,
      metadata: const {'is_she': true, 'has_main_model': true},
    );
    final unset = agent(
      id: SheService.sheId,
      protocol: ProtocolType.peer,
      metadata: const {'is_she': true},
    );
    final local = agent(
      id: 'local-1',
      protocol: ProtocolType.acp,
      metadata: const {'llm_provider': 'openai'},
    );

    expect(sheHasMainModel(she), isTrue);
    expect(sheHasMainModel(unset), isFalse);
    expect(sheHasMainModel(local), isTrue);
  });

  test('Hub 元数据写入缓存时不留密钥，并能对上本机模型', () {
    final metadata = <String, dynamic>{
      'is_she': true,
      'main_model_id': 'local-only',
      'llm_api_key': 'sk-local',
    };
    applyHostSheModelMetadata(metadata, {
      'has_main_model': true,
      'model': 'gpt-4o',
      'base_url': 'https://api.example.com/v1',
      'api_key': 'sk-should-not-stick',
    });
    expect(metadata.containsKey('main_model_id'), isFalse);
    expect(metadata.containsKey('llm_api_key'), isFalse);
    expect(metadata.containsKey('api_key'), isFalse);
    expect(metadata['she_model'], 'gpt-4o');
    expect(metadata['has_main_model'], isTrue);
    expect(
      hostSheRegistryModelId(
        metadata,
        models: [
          (id: 'm1', model: 'gpt-4o', baseUrl: 'https://api.example.com/v1'),
          (id: 'm2', model: 'gpt-4o', baseUrl: 'https://other.example/v1'),
        ],
      ),
      'm1',
    );

    applyHostSheModelMetadata(metadata, {'has_main_model': false});
    expect(metadata.containsKey('has_main_model'), isFalse);
    expect(metadata.containsKey('she_model'), isFalse);
  });

  test('惜宝切主模型的回包在连接放行名单里', () {
    final source =
        File('lib/peer/services/peer_connection.dart').readAsStringSync();
    for (final type in const [
      'she_model_set_req',
      'she_model_set_resp',
      'agent_meta_changed',
    ]) {
      expect(source, contains("'$type'"), reason: type);
    }
  });
}

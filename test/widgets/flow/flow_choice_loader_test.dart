import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/controllers/flow/flow_executor.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/widgets/flow/flow_field_editors.dart';
import 'package:shepaw/widgets/flow/flow_node_inspector.dart';

import '../../storage/test_harness.dart';

/// A3 / A10：生产用 [defaultFlowChoiceLoader] 的「完成才采信、各请求互不拖累」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  final svc = PeerAgentClientService.instance;
  final created = <String>[];

  setUpAll(() async {
    await StorageTestHarness.init();
    SharedPreferences.setMockInitialValues({});
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    db = getIt<LocalDatabaseService>();
    await db.database;
  });

  setUp(() {
    svc.debugResetPeerMetaForTest();
  });

  tearDown(() async {
    svc.debugResetPeerMetaForTest();
    for (final id in created) {
      await db.deleteRemoteAgent(id);
      await db.deletePeerAgentMeta(id);
    }
    created.clear();
  });

  Future<void> createAgent({
    required String peerId,
    required String remoteId,
  }) async {
    final localId = 'peeragent_${peerId}_$remoteId';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.createRemoteAgent(RemoteAgent(
      id: localId,
      name: localId,
      token: 'tok',
      endpoint: 'peer://$peerId/$localId',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      metadata: {
        'source_peer_id': peerId,
        'remote_agent_id': remoteId,
      },
      createdAt: now,
      updatedAt: now,
    ));
    created.add(localId);
  }

  Future<void> seedModels(String localId, List<String> values) =>
      db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
        agentId: localId,
        kind: PeerAgentMetaKind.models,
        payload: {
          'models': [
            for (final v in values)
              {'value': v, 'display_name': v, 'description': ''},
          ],
          'current': values.isEmpty ? null : values.first,
          'switchable': true,
        },
        fetchedAt: 1,
      ));

  Future<void> seedModes(String localId, List<String> values) =>
      db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
        agentId: localId,
        kind: PeerAgentMetaKind.modes,
        payload: {
          'modes': [
            for (final v in values) {'value': v, 'display_name': v},
          ],
          'current': values.isEmpty ? null : values.first,
        },
        fetchedAt: 1,
      ));

  /// 收到请求后把应答塞回控制帧入口（和真实主机一样异步回包）。
  void reply(String peerId, String type, Map<String, dynamic> data) {
    scheduleMicrotask(() => svc.debugInjectControlForTest(
          type,
          data,
          peerId: peerId,
        ));
  }

  test('A3 completed=true 的空列表不拿旧缓存回填', () async {
    const peerId = 'peer-a3';
    const remoteId = 'agent-a3';
    const localId = 'peeragent_peer-a3_agent-a3';
    await createAgent(peerId: peerId, remoteId: remoteId);
    await seedModels(localId, ['m-old']);

    svc.debugSendControlOverride = (peer, frame) async {
      switch (frame['type']) {
        case 'agent_models_req':
          reply(peerId, 'agent_models_resp', {
            'agent_id': remoteId,
            'models': const [],
            'switchable': true,
          });
        case 'agent_modes_req':
          reply(peerId, 'agent_modes_resp', {
            'agent_id': remoteId,
            'modes': const [],
          });
      }
      return true;
    };

    final shownCache = <FlowChoiceBundle>[];
    final bundle = await defaultFlowChoiceLoader(
      FlowExecutor.agent(remoteId),
      peerId: peerId,
      roles: const {},
      onCached: shownCache.add,
    );

    // 缓存先显示（旧模型）……
    expect(shownCache, isNotEmpty);
    expect(
      shownCache.first.models.options.map((o) => o.value),
      contains('m-old'),
    );
    // ……主机明确回答了「没有模型」之后，旧缓存必须让位给空列表。
    expect(
      bundle.models.options.map((o) => o.value),
      isEmpty,
      reason: 'completed=true + models=[] 是合法答案，不能用缓存回填',
    );
  });

  test('A10 fetchModes 抛异常时 fetchModels 的新结果仍然生效', () async {
    const peerId = 'peer-a10';
    const remoteId = 'agent-a10';
    const localId = 'peeragent_peer-a10_agent-a10';
    await createAgent(peerId: peerId, remoteId: remoteId);
    await seedModels(localId, ['m-old']);
    await seedModes(localId, ['mode-old']);

    svc.debugSendControlOverride = (peer, frame) async {
      switch (frame['type']) {
        case 'agent_modes_req':
          throw StateError('modes backend down');
        case 'agent_models_req':
          scheduleMicrotask(() => svc.debugInjectControlForTest(
                'agent_models_resp',
                {
                  'agent_id': remoteId,
                  'models': [
                    {'value': 'm-new', 'display_name': 'New'},
                  ],
                  'switchable': true,
                },
                peerId: peerId,
              ));
      }
      return true;
    };

    final bundle = await defaultFlowChoiceLoader(
      FlowExecutor.agent(remoteId),
      peerId: peerId,
      roles: const {},
      onCached: (_) {},
    );

    expect(
      bundle.models.options.map((o) => o.value),
      contains('m-new'),
      reason: 'modes 失败不该把 models 的成功结果一起丢掉',
    );
    // 失败的那一路退回缓存。
    expect(
      bundle.modes.options.map((o) => o.value),
      contains('mode-old'),
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_connection.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/local_database_service.dart';

import '../storage/test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LocalDatabaseService db;
  final svc = PeerAgentClientService.instance;
  final created = <String>[];

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    if (!getIt.isRegistered<LocalDatabaseService>()) {
      getIt.registerSingleton<LocalDatabaseService>(LocalDatabaseService());
    }
    db = getIt<LocalDatabaseService>();
    await db.database;
    svc.debugResetPeerMetaForTest();
    db.onRemoteAgentDeleted = null;
  });

  tearDown(() async {
    svc.debugResetPeerMetaForTest();
    db.onRemoteAgentDeleted = null;
    for (final id in created) {
      await db.deleteRemoteAgent(id);
      await db.deletePeerAgentMeta(id);
    }
    created.clear();
  });

  PeerAgentModel model(String value, [String? name]) => PeerAgentModel(
        value: value,
        displayName: name ?? value,
      );

  Future<void> insertPeer(String id, String peerId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.createRemoteAgent(RemoteAgent(
      id: id,
      name: id,
      token: 'tok',
      endpoint: 'peer://$peerId/$id',
      protocol: ProtocolType.peer,
      connectionType: ConnectionType.websocket,
      metadata: {
        'source_peer_id': peerId,
        'remote_agent_id': id,
      },
      createdAt: now,
      updatedAt: now,
    ));
    created.add(id);
  }

  Future<void> seedModels(
    String id, {
    String current = 'm1',
    bool switchable = true,
  }) {
    return db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
      agentId: id,
      kind: PeerAgentMetaKind.models,
      payload: {
        'models': [model('m1', 'One').toJson()],
        'current': current,
        'switchable': switchable,
      },
      fetchedAt: 1,
    ));
  }

  Future<T> poll<T>(
    Future<T> Function() read,
    bool Function(T value) ready,
  ) async {
    for (var i = 0; i < 40; i++) {
      final value = await read();
      if (ready(value)) return value;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('timed out waiting for cache');
  }

  group('PeerAgentModel / PeerAgentMode', () {
    test('toJson round-trips the wire fields', () {
      final parsed = PeerAgentModel.fromJson(model('gpt', 'GPT').toJson());
      expect(parsed?.value, 'gpt');
      expect(parsed?.displayName, 'GPT');
      expect(parsed?.description, '');

      final mode = PeerAgentMode.fromJson(
        PeerAgentMode(value: 'plan', displayName: 'Plan', description: 'think')
            .toJson(),
      );
      expect(mode?.value, 'plan');
      expect(mode?.displayName, 'Plan');
      expect(mode?.description, 'think');
    });
  });

  group('PeerAgentMetaCacheDao', () {
    test('upsert and get round-trip', () async {
      const id = 'meta-roundtrip';
      created.add(id);
      await db.upsertPeerAgentMeta(const PeerAgentMetaCacheEntry(
        agentId: id,
        kind: PeerAgentMetaKind.soul,
        payload: {'soul': 'hello', 'editable': true},
        fetchedAt: 42,
      ));
      final row = await db.getPeerAgentMeta(id, PeerAgentMetaKind.soul);
      expect(row?.payload['soul'], 'hello');
      expect(row?.payload['editable'], true);
      expect(row?.scope, '');
      expect(row?.fetchedAt, 42);
    });

    test('deleteRemoteAgent removes cache rows in the same delete', () async {
      const id = 'meta-delete';
      await insertPeer(id, 'peer-del');
      await seedModels(id);
      await db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
        agentId: id,
        kind: PeerAgentMetaKind.commands,
        payload: {
          'commands': [
            const SlashCommandInfo(name: 'compact').toJson(),
          ],
        },
        fetchedAt: 2,
      ));
      db.onRemoteAgentDeleted = svc.forgetPeerAgentMeta;
      await svc.debugWarmSlashCommandsForTest();
      expect(svc.getSlashCommands(id).map((c) => c.name), ['compact']);

      final seen = <List<SlashCommandInfo>>[];
      final sub = svc.slashCommandsStream(id).listen(seen.add);
      await db.deleteRemoteAgent(id);
      created.remove(id);

      expect(await db.getRemoteAgentById(id), isNull);
      expect(await db.getPeerAgentMeta(id, PeerAgentMetaKind.models), isNull);
      expect(await db.getPeerAgentMeta(id, PeerAgentMetaKind.commands), isNull);
      expect(svc.getSlashCommands(id), isEmpty);
      expect(seen, isNotEmpty);
      expect(seen.last, isEmpty);
      await sub.cancel();
    });

    test('clearAllData drops the meta cache', () async {
      const id = 'meta-reset';
      created.add(id);
      await seedModels(id);
      await db.clearAllData();
      expect(await db.getPeerAgentMeta(id, PeerAgentMetaKind.models), isNull);
    });
  });

  group('PeerAgentClientService meta cache writes', () {
    test('agent_models_resp is stored, including an empty list', () async {
      const id = 'meta-models';
      created.add(id);
      svc.debugSendControlOverride = (peerId, json) async {
        Future<void>.microtask(() {
          svc.debugInjectControlForTest('agent_models_resp', {
            'agent_id': id,
            'models': [
              {'value': 'm2', 'display_name': 'Two', 'description': 'd'},
            ],
            'current': 'm2',
          });
        });
        return true;
      };
      final outcome = await svc.fetchModelsResult(
        peerId: 'peer',
        remoteAgentId: id,
      );
      expect(outcome.completed, isTrue);
      expect(outcome.list.switchable, isTrue);
      expect(outcome.list.current, 'm2');

      final cached = await poll(
        () => svc.cachedModels(id),
        (value) => value != null && value.current == 'm2',
      );
      expect(cached?.models.single.displayName, 'Two');
      expect(cached?.switchable, isTrue);

      svc.debugSendControlOverride = (peerId, json) async {
        Future<void>.microtask(() {
          svc.debugInjectControlForTest('agent_models_resp', {
            'agent_id': id,
            'models': const [],
            'switchable': false,
          });
        });
        return true;
      };
      final empty = await svc.fetchModelsResult(
        peerId: 'peer',
        remoteAgentId: id,
      );
      expect(empty.completed, isTrue);
      expect(empty.list.models, isEmpty);
      expect(empty.list.switchable, isFalse);
      final cleared = await poll(
        () => svc.cachedModels(id),
        (value) => value != null && value.models.isEmpty,
      );
      expect(cleared?.switchable, isFalse);
    });

    test('fetch timeout leaves the previous cache alone', () async {
      const id = 'meta-timeout';
      created.add(id);
      await seedModels(id, current: 'kept');
      svc.debugMetaFetchTimeoutOverride = const Duration(milliseconds: 30);
      svc.debugSendControlOverride = (peerId, json) async => true;
      final outcome = await svc.fetchModelsResult(
        peerId: 'peer',
        remoteAgentId: id,
      );
      expect(outcome.completed, isFalse);
      final cached = await svc.cachedModels(id);
      expect(cached?.current, 'kept');
      expect(cached?.models.single.value, 'm1');
    });

    test('agent_soul_resp with an error does not write', () async {
      const id = 'meta-soul-err';
      created.add(id);
      await db.upsertPeerAgentMeta(const PeerAgentMetaCacheEntry(
        agentId: id,
        kind: PeerAgentMetaKind.soul,
        payload: {'soul': 'stay', 'editable': false},
        fetchedAt: 1,
      ));
      svc.debugInjectControlForTest('agent_soul_resp', {
        'agent_id': id,
        'ok': false,
        'error': 'denied',
      });
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final cached = await svc.cachedSoul(id);
      expect(cached?.soul, 'stay');
      expect(cached?.editable, isFalse);
    });

    test('setModel updates current only when the response is ok', () async {
      const id = 'meta-set-model';
      created.add(id);
      await seedModels(id, current: 'm1', switchable: false);

      svc.debugSendControlOverride = (peerId, json) async {
        Future<void>.microtask(() {
          svc.debugInjectControlForTest('agent_models_set_resp', {
            'agent_id': id,
            'model': 'm9',
            'ok': false,
          });
        });
        return true;
      };
      expect(
        await svc.setModel(peerId: 'peer', remoteAgentId: id, model: 'm9'),
        isFalse,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect((await svc.cachedModels(id))?.current, 'm1');
      expect((await svc.cachedModels(id))?.switchable, isFalse);

      svc.debugSendControlOverride = (peerId, json) async {
        Future<void>.microtask(() {
          svc.debugInjectControlForTest('agent_models_set_resp', {
            'agent_id': id,
            'model': 'm2',
            'ok': true,
          });
        });
        return true;
      };
      expect(
        await svc.setModel(peerId: 'peer', remoteAgentId: id, model: 'm2'),
        isTrue,
      );
      final cached = await poll(
        () => svc.cachedModels(id),
        (value) => value?.current == 'm2',
      );
      expect(cached?.models.single.value, 'm1');
      expect(cached?.switchable, isFalse);
    });
  });

  group('slash command warmup', () {
    test('warmed commands are readable, then refresh once per connection',
        () async {
      const id = 'meta-commands';
      const peerId = 'peer-cmd';
      await insertPeer(id, peerId);
      await db.upsertPeerAgentMeta(PeerAgentMetaCacheEntry(
        agentId: id,
        kind: PeerAgentMetaKind.commands,
        payload: {
          'commands': [
            const SlashCommandInfo(name: 'warm').toJson(),
          ],
        },
        fetchedAt: 1,
      ));

      final seen = <List<SlashCommandInfo>>[];
      final sub = svc.slashCommandsStream(id).listen(seen.add);
      await svc.debugWarmSlashCommandsForTest();
      await Future<void>.delayed(Duration.zero);
      expect(svc.getSlashCommands(id).map((c) => c.name), ['warm']);
      expect(seen.single.map((c) => c.name), ['warm']);

      var calls = 0;
      svc.debugConnectedPeerIdsOverride = {peerId};
      svc.debugSendControlOverride = (pid, json) async {
        if (json['type'] == 'agent_commands_req') {
          calls++;
          final agentId = json['agent_id'] as String;
          Future<void>.microtask(() {
            svc.debugInjectControlForTest(
              'agent_commands_resp',
              {
                'agent_id': agentId,
                'commands': [
                  {'name': 'fresh'},
                ],
              },
              peerId: pid,
            );
          });
        }
        return true;
      };

      await svc.ensureCommandsForLocalAgent(id);
      expect(calls, 1);
      expect(svc.getSlashCommands(id).map((c) => c.name), ['fresh']);

      await svc.ensureCommandsForLocalAgent(id);
      expect(calls, 1);

      svc.debugInjectConnectionEvent(PeerConnectionEvent(
        peerId: peerId,
        type: PeerConnectionEventType.disconnected,
      ));
      await svc.ensureCommandsForLocalAgent(id);
      expect(calls, 2);
      await sub.cancel();
    });
  });
}

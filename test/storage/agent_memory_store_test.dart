import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent_memory_entry.dart';
import 'package:shepaw/services/agent_memory_store_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/memory_paths.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
    StorageTestHarness.installMemoryPouchScope(pouchId: 'test-pouch');
  });

  tearDown(() async {
    await AgentMemoryStoreService.forAgent('agent-mem-test').deleteAll();
  });

  test('add / get / query 走 agent scope', () async {
    final svc = AgentMemoryStoreService.forAgent('agent-mem-test');
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await svc.addMemory(AgentMemoryEntry(
      memoryContent: 'user likes tea',
      memoryTime: now,
      memoryType: MemoryType.knowledge,
      memoryKeywords: const ['tea'],
      createdAt: now,
      updatedAt: now,
    ));
    expect(id, greaterThan(0));

    final got = await svc.getMemory(id);
    expect(got?.memoryContent, 'user likes tea');

    final hits = await svc.queryByKeyword('tea');
    expect(hits, isNotEmpty);

    final scoped = await StoreService.instance.scopeStore();
    final meta = await scoped.meta(
      MemoryPaths.scopeFor('agent-mem-test'),
      MemoryPaths.entryPath(id),
    );
    expect(meta, isNotNull);
    expect(meta!.size, greaterThan(0));
  });

  test('MemoryPaths 布局', () {
    expect(MemoryPaths.agentRoot('a/b'), 'a_b');
    expect(MemoryPaths.scopeFor('agent1').id, 'agent:agent1');
    expect(MemoryPaths.entryPath(3), 'memory/entries/3.json');
    expect(MemoryPaths.metaPath(), 'memory/meta.json');
    expect(
      MemoryPaths.uriFor(
        pouchId: 'test-pouch',
        agentId: 'agent1',
        path: MemoryPaths.metaPath(),
      ),
      'pouch://test-pouch/agent:agent1/memory/meta.json',
    );
  });

  test('v2 cognition → v3 映射', () {
    expect(
      MemoryPaths.v3PathForLegacy('agent1', 'agent1/soul.md'),
      'identity/soul.md',
    );
    expect(
      MemoryPaths.v3PathForLegacy('agent1', 'agent1/entries/7.json'),
      'memory/entries/7.json',
    );
    expect(
      MemoryPaths.v3PathForLegacy(
        'agent1',
        'agent1/peers/peer_1/entries/7.json',
      ),
      isNull,
    );
    expect(
      MemoryPaths.v3PathForLegacy(
        'agent1',
        'agent1/peers/peer_1/entries/7.json',
        peerClientId: 'peer_1',
      ),
      'memory/peers/peer_1/entries/7.json',
    );
  });

  test('v2 cognition 数据一次性迁到 v3 后不再读 v2', () async {
    const agentId = 'agent-mem-migrate-test';
    final svc = AgentMemoryStoreService.forAgent(agentId);
    try {
      final deviceId = await DeviceIdentity.deviceId();
      final local = await StoreService.instance.localStore();
      final legacyRoot = MemoryPaths.legacyScopedRoot(agentId);
      final entry = AgentMemoryEntry(
        memoryId: 7,
        memoryContent: 'legacy entry',
        memoryTime: 1000,
        memoryType: MemoryType.knowledge,
        memoryKeywords: const ['legacy'],
        createdAt: 1000,
        updatedAt: 1000,
      );
      await local.putBytes(
        deviceId: deviceId,
        space: StoreSpace.cognition,
        path: '$legacyRoot/soul.md',
        bytes: Uint8List.fromList(utf8.encode('legacy soul body')),
      );
      await local.putBytes(
        deviceId: deviceId,
        space: StoreSpace.cognition,
        path: '$legacyRoot/entries/7.json',
        bytes: Uint8List.fromList(utf8.encode(jsonEncode(entry.toJson()))),
      );
      await local.putBytes(
        deviceId: deviceId,
        space: StoreSpace.cognition,
        path: '$legacyRoot/meta.json',
        bytes: Uint8List.fromList(
          utf8.encode(jsonEncode({'next_id': 42, 'schema_version': 1})),
        ),
      );

      final got = await svc.getMemory(7);
      expect(got?.memoryContent, 'legacy entry');

      final scoped = await StoreService.instance.scopeStore();
      final scope = MemoryPaths.scopeFor(agentId);
      expect(await scoped.meta(scope, MemoryPaths.soulPath()), isNotNull);
      expect(
        utf8.decode((await scoped.read(scope, MemoryPaths.soulPath()))!),
        contains('legacy soul body'),
      );
      expect(await scoped.meta(scope, MemoryPaths.entryPath(7)), isNotNull);

      // 已标记迁移完成，v3 删掉后不再回落到 v2 的 legacy 文件。
      await scoped.delete(scope, MemoryPaths.entryPath(7));
      expect(await svc.getMemory(7), isNull);

      // v2 meta 的 next_id 也要带过来，避免新记忆从 1 重新编号。
      final now = DateTime.now().millisecondsSinceEpoch;
      final newId = await svc.addMemory(AgentMemoryEntry(
        memoryContent: 'after migration',
        memoryTime: now,
        memoryType: MemoryType.knowledge,
        memoryKeywords: const ['after'],
        createdAt: now,
        updatedAt: now,
      ));
      expect(newId, 42);
    } finally {
      await svc.deleteAll();
      await svc.close();
    }
  });
}

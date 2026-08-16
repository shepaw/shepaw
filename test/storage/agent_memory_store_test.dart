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
  });

  tearDown(() async {
    await AgentMemoryStoreService.forAgent('agent-mem-test').deleteAll();
  });

  test('add / get / query 走 cognition 空间', () async {
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

    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final meta = await store.meta(
      deviceId,
      StoreSpace.cognition,
      MemoryPaths.entryJson('agent-mem-test', id),
    );
    expect(meta['size'] as int, greaterThan(0));
  });

  test('MemoryPaths 布局', () {
    expect(MemoryPaths.agentRoot('a/b'), 'a_b');
    expect(MemoryPaths.entryJson('agent1', 3), 'agent1/entries/3.json');
    expect(
      MemoryPaths.uri(deviceId: 'aaaaaaaaaaaaaaaa', relPath: 'agent1/meta.json'),
      'store://cognition/aaaaaaaaaaaaaaaa/agent1/meta.json',
    );
  });
}

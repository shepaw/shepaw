import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/agent_memory_store_service.dart';
import 'package:shepaw/services/cognition_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/memory_paths.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/workspace_binding_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
    StorageTestHarness.installMemoryPouchScope(pouchId: 'test-pouch');
  });

  tearDown(() async {
    await AgentMemoryStoreService.forAgent('agent-soul-ws').deleteAll();
  });

  test('soul 权威写入 agent:<aid>/identity/soul.md', () async {
    await CognitionService.instance
        .updateAgentSoul('agent-soul-ws', 'I am a pouch soul.');
    final got = await CognitionService.instance.getAgentSoul('agent-soul-ws');
    expect(got, contains('pouch soul'));

    final scoped = await StoreService.instance.scopeStore();
    final meta = await scoped.meta(
      MemoryPaths.scopeFor('agent-soul-ws'),
      MemoryPaths.soulPath(),
    );
    expect(meta, isNotNull);
    expect(meta!.size, greaterThan(0));
  });

  test('WorkspaceBindingService parse + save', () async {
    expect(
      WorkspaceBindingService.parseWorkspaceIds(
        'workspace_ids: ["ws-a", "ws-b"]\n',
      ),
      ['ws-a', 'ws-b'],
    );
    await StoreService.instance.writeWorkspaceFile(
      homeDeviceId: await DeviceIdentity.deviceId(),
      relPath: 'ws-bind-demo/readme.txt',
      content: Uint8List.fromList('hi'.codeUnits),
    );
    await WorkspaceBindingService.instance
        .saveBoundIds('agent-soul-ws', ['ws-bind-demo']);
    final bound =
        await WorkspaceBindingService.instance.loadBoundIds('agent-soul-ws');
    expect(bound, contains('ws-bind-demo'));
    final peeked =
        await WorkspaceBindingService.instance.peekBoundIds('agent-soul-ws');
    expect(peeked, bound);
  });
}

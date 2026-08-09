import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/context_bundle.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/runtime_mirror_service.dart';
import 'package:shepaw/storage/runtime_paths.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('ContextBundle.fromJson + collectUris', () {
    final bundle = ContextBundle.fromJson({
      'schema_version': 1,
      'owner_id': 'agent-a',
      'source_device': 'aaaaaaaaaaaaaaaa',
      'updated_at': '2026-01-01T00:00:00Z',
      'soul_uri': 'store://runtime/aaaaaaaaaaaaaaaa/agent-a/soul.md',
      'memory_uri': 'store://runtime/aaaaaaaaaaaaaaaa/agent-a/memory.md',
      'workspace_refs': ['store://workspaces/aaaaaaaaaaaaaaaa/ws1/'],
      'channels': {
        'ch1': {'session_uri': 'store://runtime/aaaaaaaaaaaaaaaa/agent-a/ch1/sessions/session.json'},
      },
    });
    expect(bundle.ownerId, 'agent-a');
    final uris = bundle.collectUris(preferChannelId: 'ch1');
    expect(uris, contains(bundle.soulUri));
    expect(uris, contains(bundle.memoryUri));
    expect(uris.any((u) => u.contains('ch1')), isTrue);
  });

  test('wrapWithContextBundle 追加可用上下文段', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    await mirror.ensureRuntimeScaffold('agent-bundle');

    final out = await ContextBundleService.instance.wrapWithContextBundle(
      'do the thing\n[report.md](store://artifacts/aaaaaaaaaaaaaaaa/t/report.md)',
      ownerId: 'agent-bundle',
      channelId: 'ch-1',
    );
    expect(out, contains('## 可用产物'));
    expect(out, contains('## 可用上下文'));
    expect(out, contains('agent-bundle'));

    final deviceId = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.runtime,
      RuntimePaths.contextManifest('agent-bundle'),
      0,
      1 << 16,
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(json['owner_id'], 'agent-bundle');
  });
}

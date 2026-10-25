import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/context_bundle.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/runtime_mirror_service.dart';
import 'package:shepaw/storage/runtime_paths.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

class _ScopeTransport implements PouchScopeTransport {
  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async =>
      const PouchListPage(entries: <StoreEntry>[]);

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      null;

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async =>
      const <String>[];

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      null;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {}

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {}
}

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
      'soul_uri': 'pouch://runtime/agent-a/soul.md',
      'memory_uri': 'pouch://runtime/agent-a/memory.md',
      'workspace_refs': ['pouch://workspaces/ws1/'],
      'channels': {
        'ch1': {'session_uri': 'pouch://runtime/agent-a/ch1/sessions/session.json'},
      },
    });
    expect(bundle.ownerId, 'agent-a');
    final uris = bundle.collectUris(preferChannelId: 'ch1');
    expect(uris, contains(bundle.soulUri));
    expect(uris, contains(bundle.memoryUri));
    expect(uris.any((u) => u.contains('ch1')), isTrue);
  });

  test('wrapWithContextBundle 追加 Scope Card 本轮段', () async {
    final mirror = RuntimeMirrorService.instance;
    mirror.debounce = Duration.zero;
    await mirror.ensureRuntimeScaffold('agent-bundle');

    final out = await ContextBundleService.instance.wrapWithContextBundle(
      'do the thing\n[report.md](pouch://artifacts/t/report.md)',
      ownerId: 'agent-bundle',
      channelId: 'ch-1',
    );
    expect(out, contains('## 可用产物'));
    expect(out, contains('当前储物袋作用域'));
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

  test('wrapWithContextBundle 群上下文不含个人 cognition 指引', () async {
    final out = await ContextBundleService.instance.wrapWithContextBundle(
      'do group work',
      ownerId: 'group-bundle',
      channelId: 'ch-g',
      isGroup: true,
    );
    expect(out, contains('当前储物袋作用域'));
    expect(out, contains('group-bundle'));
    expect(out, contains('非个人 cognition'));
    expect(out, isNot(contains('soul/memory/session/workspace')));
    // 没配对上袋子时不注入任何旧目录地址。
    expect(out, isNot(contains('pouch://workspaces/')));
  });

  test('群上下文：有袋子时注入 group:<gid>:shared', () async {
    const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
    StoreService.instance.scopeStoreOverride = PouchScopeStore(
      transport: _ScopeTransport(),
      pouchId: pouchId,
    );
    StoreService.instance.currentPouchIdOverride = pouchId;
    addTearDown(() {
      StoreService.instance.scopeStoreOverride = null;
      StoreService.instance.currentPouchIdOverride = null;
    });

    final out = await ContextBundleService.instance.wrapWithContextBundle(
      'do group work',
      ownerId: 'group-bundle',
      channelId: 'ch-g',
      isGroup: true,
    );

    expect(out, contains('pouch://$pouchId/group:group-bundle:shared'));
    expect(out, isNot(contains('pouch://workspaces/group-bundle/shared')));
  });
}

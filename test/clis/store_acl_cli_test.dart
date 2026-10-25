import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/store/store_namespace.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/storage/artifact_service.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_service.dart';

import '../storage/test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  final writeCmd = StoreNamespace.instance.commands['write']!;
  final readCmd = StoreNamespace.instance.commands['read']!;
  final searchCmd = StoreNamespace.instance.commands['search']!;

  Future<Map<String, dynamic>> asAgent(
    String agentId,
    Future<Map<String, dynamic>> Function() body,
  ) {
    return ChatAgentScope.runScoped(agentId: agentId, body: body);
  }

  test('store write ignores spoofed agent_id/owner flags', () async {
    final result = await asAgent('agent-b', () {
      return writeCmd.execute({
        'filename': 'spoof.txt',
        'content': 'from-b',
        'agent_id': 'agent-a',
        'owner': 'agent-a',
      });
    });
    expect(result['success'], isTrue, reason: '$result');
    expect(result['uri'], contains('/agent-b/'));
    expect(result['uri'], isNot(contains('/agent-a/')));
  });

  test('non-She cannot read another agent runtime URI', () async {
    final written = await asAgent('agent-a', () {
      return writeCmd.execute({
        'filename': 'secret.txt',
        'content': 'a-private',
      });
    });
    expect(written['success'], isTrue, reason: '$written');
    final uri = written['uri'] as String;

    final denied = await asAgent('agent-b', () {
      return readCmd.execute({'uri': uri});
    });
    expect(denied['success'], isFalse);
    expect(denied['error'], contains('acl_denied'));

    final sheRead = await asAgent(SheService.sheId, () {
      return readCmd.execute({'uri': uri});
    });
    expect(sheRead['success'], isTrue, reason: '$sheRead');
    expect(sheRead['content'], 'a-private');
  });

  test('non-She search without uri hides other agent runtime hits', () async {
    await asAgent('agent-a', () {
      return writeCmd.execute({
        'filename': 'unique-acl-token-a.md',
        'content': 'unique-acl-token-a',
      });
    });
    await asAgent('agent-b', () {
      return writeCmd.execute({
        'filename': 'unique-acl-token-b.md',
        'content': 'unique-acl-token-b',
      });
    });

    final searched = await asAgent('agent-b', () {
      return searchCmd.execute({'query': 'unique-acl-token'});
    });
    expect(searched['success'], isTrue, reason: '$searched');
    final uris = [
      for (final hit in (searched['results'] as List))
        (hit as Map)['uri'].toString(),
    ];
    expect(uris.any((u) => u.contains('/agent-b/')), isTrue);
    expect(uris.any((u) => u.contains('/agent-a/')), isFalse);
  });

  test('store write rejects unsupported --space instead of falling back', () async {
    final result = await asAgent('agent-b', () {
      return writeCmd.execute({
        'filename': 'note.md',
        'content': 'x',
        'space': 'files',
      });
    });
    expect(result['success'], isFalse);
    expect(result['error'], contains('unsupported --space files'));
  });

  test('store search --task keeps only that task artifacts', () async {
    for (final task in ['task-scope', 'other-task']) {
      await asAgent('agent-a', () {
        return writeCmd.execute({
          'filename': 'r-$task.md',
          'content': 'task-scope-body',
          'task': task,
        });
      });
    }

    final hit = await asAgent('agent-a', () {
      return searchCmd.execute({'task': 'task-scope'});
    });
    expect(hit['success'], isTrue, reason: '$hit');
    final uris = [
      for (final h in (hit['results'] as List)) (h as Map)['uri'].toString(),
    ];
    expect(uris.any((u) => u.contains('/artifacts/task-scope/')), isTrue);
    expect(uris.any((u) => u.contains('/artifacts/other-task/')), isFalse);
  });

  test('store write --desc lands in a sidecar and maps back on search', () async {
    final written = await asAgent('agent-a', () {
      return writeCmd.execute({
        'filename': 'desc-note.md',
        'content': 'plain body',
        'desc': 'zzz-desc-token',
      });
    });
    expect(written['meta_written'], isTrue, reason: '$written');

    final hit = await asAgent('agent-a', () {
      return searchCmd.execute({'desc': 'zzz-desc-token'});
    });
    expect(hit['success'], isTrue, reason: '$hit');
    expect(hit['total'], 1);
    final uri = ((hit['results'] as List).first as Map)['uri'].toString();
    expect(uri, endsWith('desc-note.md'));
    expect(uri, isNot(contains('.meta.json')));
  });

  test('mapArtifactMetaHits folds duplicates and drops orphan sidecars', () async {
    const space = 'runtime';
    const device = '0123456789abcdef';
    Map<String, dynamic> hit(String path) => {
          'space': space,
          'device': device,
          'path': path,
          'uri': 'pouch://$space/$device/$path',
        };
    final hits = [
      hit('a/artifacts/t/r.md'),
      hit('a/artifacts/t/r.md${ArtifactService.metaSuffix}'),
      hit('a/artifacts/t/gone.md${ArtifactService.metaSuffix}'),
    ];

    final folded = await mapArtifactMetaHits(hits,
        exists: (_, __, path) async => path.endsWith('r.md'));
    expect(folded.length, 1);
    expect(folded.single['path'], 'a/artifacts/t/r.md');

    final metaOnly = await mapArtifactMetaHits(hits, metaOnly: true,
        exists: (_, __, path) async => path.endsWith('r.md'));
    expect(metaOnly.length, 1);
    expect(metaOnly.single['via'], 'meta');
    expect(metaOnly.single['uri'], endsWith('r.md'));
  });

  test('shared files space remains readable to non-She', () async {
    final written = await asAgent('agent-a', () {
      return writeCmd.execute({
        'filename': 'shared-note.md',
        'content': 'public-ok',
        'space': 'public',
      });
    });
    expect(written['success'], isTrue, reason: '$written');
    final uri = written['uri'] as String;

    final read = await asAgent('agent-b', () {
      return readCmd.execute({'uri': uri});
    });
    expect(read['success'], isTrue, reason: '$read');
    expect(read['content'], 'public-ok');
  });

  group('v3 scope 地址', () {
    const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
    late _ScopeTransport transport;
    final listCmd = StoreNamespace.instance.commands['list']!;

    setUp(() {
      transport = _ScopeTransport();
      transport.files['agent:agent-a/files/note.md'] = Uint8List.fromList(
        utf8.encode('a-private'),
      );
      StoreService.instance.scopeStoreOverride =
          PouchScopeStore(transport: transport, pouchId: pouchId);
      StoreService.instance.currentPouchIdOverride = pouchId;
    });

    tearDown(() {
      StoreService.instance.scopeStoreOverride = null;
      StoreService.instance.currentPouchIdOverride = null;
    });

    test('助手私有区：本人能读，别人 acl_denied', () async {
      const uri = 'pouch://$pouchId/agent:agent-a/files/note.md';

      final denied = await asAgent('agent-b', () {
        return readCmd.execute({'uri': uri});
      });
      expect(denied['success'], isFalse);
      expect(denied['error'], contains('acl_denied'));

      final own = await asAgent('agent-a', () {
        return readCmd.execute({'uri': uri});
      });
      expect(own['success'], isTrue, reason: '$own');
      expect(own['content'], 'a-private');
    });

    test('list 认 v3 地址，返回 scope 内相对路径', () async {
      final listed = await asAgent('agent-a', () {
        return listCmd.execute({
          'uri': 'pouch://$pouchId/agent:agent-a/files',
        });
      });
      expect(listed['success'], isTrue, reason: '$listed');
      final entries = listed['entries'] as List<dynamic>;
      expect(
        entries.map((e) => (e as Map<String, dynamic>)['path']),
        ['files/note.md'],
      );
    });
  });
}

/// 最小内存 scope transport：只够 read/list 用。
class _ScopeTransport implements PouchScopeTransport {
  final files = <String, Uint8List>{};

  String _key(PouchScope scope, String path) => '${scope.id}/$path';

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
      files.containsKey(_key(scope, path))
          ? PouchFileMeta(path: path, size: 1, version: 1, mtimeMs: 0)
          : null;

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async {
    final head = '${scope.id}/';
    final dir = prefix?.trim() ?? '';
    final entries = <StoreEntry>[];
    for (final entry in files.entries) {
      if (!entry.key.startsWith(head)) continue;
      final path = entry.key.substring(head.length);
      if (dir.isNotEmpty && path != dir && !path.startsWith('$dir/')) continue;
      entries.add(StoreEntry(
        path: path,
        size: entry.value.length,
        sha256: '',
        mtimeMs: 0,
      ));
    }
    return PouchListPage(entries: entries);
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      files[_key(scope, path)];

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    files[_key(scope, path)] = bytes;
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    files.remove(_key(scope, path));
  }
}

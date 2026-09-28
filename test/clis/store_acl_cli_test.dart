import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/store/store_namespace.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/storage/artifact_service.dart';
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
          'uri': 'store://$space/$device/$path',
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
}

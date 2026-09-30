import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/runtime_retention.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  late Directory tmp;
  late LocalStore store;
  const dev = 'aaaaaaaaaaaaaaaa';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('runtime_retention_test');
    store = LocalStore(
      root: tmp,
      versionCoalesceWindow: Duration.zero,
    );
    store.debugSkipVolumeQuota = true;
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> put(String path, String text) {
    final bytes = Uint8List.fromList(utf8.encode(text));
    return store.putBytes(
      deviceId: dev,
      space: StoreSpace.runtime,
      path: path,
      bytes: bytes,
    );
  }

  test('session archives keep the newest 3 and leave session.json', () async {
    await put('agent/ch/sessions/session.json', 'live');
    for (final year in ['2020', '2021', '2022', '2023', '2024']) {
      await put('agent/ch/sessions/archive-$year.json', year);
    }

    expect(await store.pruneSessionArchives(dev, keep: 3), 2);

    final dir = Directory(
        p.join(tmp.path, dev, 'runtime', 'agent', 'ch', 'sessions'));
    final names = await dir
        .list()
        .map((e) => p.basename(e.path))
        .toList();
    names.sort();
    expect(names, [
      'archive-2022.json',
      'archive-2023.json',
      'archive-2024.json',
      'session.json',
    ]);
  });

  test('version keep_last drops oldest unprotected blobs', () async {
    final dir = Directory(
        p.join(tmp.path, '.versions', dev, 'runtime', 'note.md'));
    await dir.create(recursive: true);
    String shaOf(String text) =>
        crypto.sha256.convert(utf8.encode(text)).toString();
    final versions = [
      {'v': 1, 'sha256': shaOf('v1'), 'protected': true, 'size': 2},
      {'v': 2, 'sha256': shaOf('v2'), 'protected': false, 'size': 2},
      {'v': 3, 'sha256': shaOf('v3'), 'protected': false, 'size': 2},
      {'v': 4, 'sha256': shaOf('v4'), 'protected': false, 'size': 2},
    ];
    for (final entry in versions) {
      await File(p.join(dir.path, entry['sha256'] as String))
          .writeAsString('blob');
    }
    await File(p.join(dir.path, 'index.json'))
        .writeAsString(jsonEncode({'versions': versions}));

    expect(await store.pruneOldVersions(dev, keep: 2), 2);

    final index = jsonDecode(await File(p.join(dir.path, 'index.json'))
        .readAsString()) as Map<String, dynamic>;
    final kept = [
      for (final e in index['versions'] as List) (e as Map)['v']
    ]..sort();
    expect(kept, [1, 4]);
    expect(await File(p.join(dir.path, shaOf('v1'))).exists(), isTrue);
    expect(await File(p.join(dir.path, shaOf('v4'))).exists(), isTrue);
    expect(await File(p.join(dir.path, shaOf('v2'))).exists(), isFalse);
    expect(await File(p.join(dir.path, shaOf('v3'))).exists(), isFalse);
  });

  test('orphan attachments skip live refs and files newer than minAge',
      () async {
    final live = 'agent/ch/attachments/${'ab' * 32}';
    final orphan = 'agent/ch/attachments/${'cd' * 32}';
    final fresh = 'agent/ch/attachments/${'ef' * 32}';
    await put(live, 'live');
    await put(orphan, 'orphan');
    await put(fresh, 'fresh');
    final old = DateTime.now().subtract(const Duration(days: 2));
    for (final rel in [live, orphan]) {
      final file = File(p.join(tmp.path, dev, 'runtime', rel));
      await file.setLastModified(old);
    }

    final removed = await store.pruneOrphanAttachments(
      dev,
      {live},
      minAge: const Duration(hours: 24),
    );
    expect(removed, 1);
    expect(
        await File(p.join(tmp.path, dev, 'runtime', live)).exists(), isTrue);
    expect(
        await File(p.join(tmp.path, dev, 'runtime', orphan)).exists(),
        isFalse);
    expect(
        await File(p.join(tmp.path, dev, 'runtime', fresh)).exists(), isTrue);
  });

  test('attachment refs only keep this device runtime paths', () {
    final refs = referencedRuntimeAttachmentPaths('aaaaaaaaaaaaaaaa', [
      'see pouch://runtime/aaaaaaaaaaaaaaaa/agent/ch/attachments/abc',
      'pouch://runtime/bbbbbbbbbbbbbbbb/agent/ch/attachments/other',
      'pouch://files/aaaaaaaaaaaaaaaa/resume.md',
    ]);
    expect(refs, {'agent/ch/attachments/abc'});
  });

  test('agent quota attention starts at 80 percent', () {
    const cap = 100;
    expect(agentQuotaNeedsAttention(79, capBytes: cap), isFalse);
    expect(agentQuotaNeedsAttention(80, capBytes: cap), isTrue);
    expect(
      agentQuotaUsedBytes({
        'devices': {
          dev: {'runtime': 10, 'cognition': 5, 'files': 100},
        },
      }, dev),
      15,
    );
  });
}

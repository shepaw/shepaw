import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/commit_retention.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  late Directory tmp;
  late LocalStore store;
  const dev = 'aaaaaaaaaaaaaaaa';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('commit_retention_test');
    store = LocalStore(root: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<void> putDir(String id, String text, {DateTime? mtime}) async {
    final c = bytesOf(text);
    final (u, _) = await store.writeBegin(
      deviceId: dev,
      space: StoreSpace.backups,
      path: '$id/f.txt',
      size: c.length,
      sha256: sha(c),
    );
    await store.writeChunk(dev, StoreSpace.backups, u, 0, c);
    await store.commit(dev, StoreSpace.backups, [u]);
    if (mtime != null) {
      final dir = Directory(p.join(tmp.path, dev, StoreSpace.backups, id));
      // Directory 无 setLastModified；用 touch 固定排序键。
      final stamp =
          '${mtime.year.toString().padLeft(4, '0')}'
          '${mtime.month.toString().padLeft(2, '0')}'
          '${mtime.day.toString().padLeft(2, '0')}'
          '${mtime.hour.toString().padLeft(2, '0')}'
          '${mtime.minute.toString().padLeft(2, '0')}'
          '.${mtime.second.toString().padLeft(2, '0')}';
      final r = await Process.run('touch', ['-t', stamp, dir.path]);
      expect(r.exitCode, 0, reason: r.stderr.toString());
    }
  }

  Future<Set<String>> backupIds() async {
    final backups = Directory(p.join(tmp.path, dev, StoreSpace.backups));
    final ids = <String>{};
    if (!await backups.exists()) return ids;
    await for (final e in backups.list()) {
      if (e is Directory) {
        final name = p.basename(e.path);
        if (!name.startsWith('.')) ids.add(name);
      }
    }
    return ids;
  }

  test('tryParse keep_last / gfs', () {
    expect(
      CommitRetention.tryParse({'policy': 'keep_last', 'keep': 4}),
      isA<KeepLastRetention>(),
    );
    expect(
      CommitRetention.tryParse({
        'policy': 'gfs',
        'exclude_prefix': 'reprotect-',
      }),
      isA<GfsRetentionPolicy>(),
    );
    expect(CommitRetention.tryParse({'policy': 'nope'}), isNull);
    expect(CommitRetention.tryParse(null), isNull);
  });

  test('keep_last 只保留最新 N 个顶层目录', () async {
    final base = DateTime.now().subtract(const Duration(days: 1));
    for (var i = 0; i < 5; i++) {
      await putDir('snap-$i', 'x$i',
          mtime: base.add(Duration(hours: i)));
    }
    final removed = await CommitRetention.apply(
      store,
      deviceId: dev,
      space: StoreSpace.backups,
      policy: const KeepLastRetention(keep: 3),
    );
    expect(removed, 2);
    expect(await backupIds(), {'snap-2', 'snap-3', 'snap-4'});
  });

  test('commit 携带 retention 时执行 keep_last', () async {
    final base = DateTime.now().subtract(const Duration(days: 1));
    for (var i = 0; i < 3; i++) {
      await putDir('old-$i', 'o$i', mtime: base.add(Duration(hours: i)));
    }
    final c = bytesOf('newest');
    final (u, _) = await store.writeBegin(
      deviceId: dev,
      space: StoreSpace.backups,
      path: 'new/f.txt',
      size: c.length,
      sha256: sha(c),
    );
    await store.writeChunk(dev, StoreSpace.backups, u, 0, c);
    final (committed, failed) = await store.commit(
      dev,
      StoreSpace.backups,
      [u],
      retention: const KeepLastRetention(keep: 2).toJson(),
    );
    expect(failed, isEmpty);
    expect(committed, isNotEmpty);
    // 刚 commit 的 new 目录 mtime≈now，应留下 new + 最新 old
    final ids = await backupIds();
    expect(ids.length, 2);
    expect(ids.contains('new'), isTrue);
  });

  test('keep_last include_prefix 不影响其他目录', () async {
    final base = DateTime.now().subtract(const Duration(days: 1));
    await putDir('db-1', 'a', mtime: base);
    await putDir('reprotect-1', 'b', mtime: base.add(const Duration(hours: 1)));
    await putDir('reprotect-2', 'c', mtime: base.add(const Duration(hours: 2)));
    await putDir('reprotect-3', 'd', mtime: base.add(const Duration(hours: 3)));
    await putDir('reprotect-4', 'e', mtime: base.add(const Duration(hours: 4)));

    final removed = await CommitRetention.apply(
      store,
      deviceId: dev,
      space: StoreSpace.backups,
      policy: const KeepLastRetention(keep: 2, includePrefix: 'reprotect-'),
    );
    expect(removed, 2);
    final ids = await backupIds();
    expect(ids.contains('db-1'), isTrue);
    expect(ids.where((id) => id.startsWith('reprotect-')).length, 2);
  });
}

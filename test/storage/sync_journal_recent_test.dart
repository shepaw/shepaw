import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/sync_journal.dart';

void main() {
  late Directory tmp;
  const owner = 'aaaaaaaaaaaaaaaa';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_journal_recent');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('recent 在出队后仍保留，delete 会移除', () async {
    final journal = SyncJournal(storeRoot: tmp, ownerDeviceId: owner);
    await journal.appendCommit(owner, 'files', const [
      (path: 'a.txt', size: 3, sha256: 'x'),
    ]);
    await journal.dequeueThrough(1);
    expect(await journal.pending(), isEmpty);

    final recent = await journal.recent();
    expect(recent, hasLength(1));
    expect(recent.single.path, 'a.txt');
    expect(recent.single.space, 'files');
    expect(recent.single.size, 3);

    await journal.appendDelete(owner, 'files', 'a.txt');
    expect(await journal.recent(), isEmpty);
  });

  test('同路径覆盖只留最新一条；缺 recent 文件时从队列种子', () async {
    final journal = SyncJournal(storeRoot: tmp, ownerDeviceId: owner);
    await journal.appendCommit(owner, 'files', const [
      (path: 'a.txt', size: 1, sha256: 'old'),
    ]);
    await journal.appendCommit(owner, 'files', const [
      (path: 'a.txt', size: 9, sha256: 'new'),
      (path: 'b.txt', size: 2, sha256: 'b'),
    ]);
    final first = await journal.recent();
    expect(first.map((e) => e.path), ['b.txt', 'a.txt']);
    expect(first.firstWhere((e) => e.path == 'a.txt').size, 9);

    final recentFile = File('${tmp.path}/.system/sync_recent.json');
    expect(await recentFile.exists(), isTrue);
    await recentFile.delete();

    final seeded = SyncJournal(storeRoot: tmp, ownerDeviceId: owner);
    final items = await seeded.recent();
    expect(items.map((e) => e.path).toSet(), {'a.txt', 'b.txt'});
    expect(items.firstWhere((e) => e.path == 'a.txt').size, 9);
  });
}

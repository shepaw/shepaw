import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/sync_journal.dart';

void main() {
  test('expandSyncPending 拆开 commit files 与 delete', () {
    final entries = [
      SyncQueueEntry(
        seq: 1,
        kind: 'commit',
        space: 'files',
        files: const [
          (path: 'a.txt', size: 10, sha256: 'x'),
          (path: 'b.txt', size: 20, sha256: 'y'),
        ],
        createdMs: 1,
      ),
      SyncQueueEntry(
        seq: 2,
        kind: 'delete',
        space: 'runtime',
        path: 'c.txt',
        createdMs: 2,
      ),
    ];
    final items = expandSyncPending(entries);
    expect(items, hasLength(3));
    expect(items[0].path, 'a.txt');
    expect(items[0].kind, 'commit');
    expect(items[0].space, 'files');
    expect(items[1].path, 'b.txt');
    expect(items[2].kind, 'delete');
    expect(items[2].path, 'c.txt');
    expect(countExpandedPending(entries), 3);

    final capped = expandSyncPending(entries, limit: 2);
    expect(capped, hasLength(2));
  });
}

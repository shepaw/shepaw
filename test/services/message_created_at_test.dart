import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('写入格式是 UTC 毫秒，和主机行一致', () {
    final at = DateTime.utc(2026, 10, 7, 2, 47, 56, 391, 123);
    expect(messageCreatedAt(at), '2026-10-07T02:47:56.391Z');
    expect(messageCreatedAt(at.toLocal()), '2026-10-07T02:47:56.391Z');
  });

  test('导入的本地时间换成 UTC，已带时区的不变', () {
    final local = DateTime(2026, 10, 7, 9, 7, 42, 730);
    expect(
      normalizeMessageCreatedAt('2026-10-07T09:07:42.730315'),
      messageCreatedAt(local),
    );
    expect(
      normalizeMessageCreatedAt('2026-10-07T02:47:56.391Z'),
      '2026-10-07T02:47:56.391Z',
    );
    expect(normalizeMessageCreatedAt('not a time'), 'not a time');
  });

  test('升级时只改不带时区的行', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('CREATE TABLE messages (id TEXT, created_at TEXT)');
    await db.insert('messages', {'id': 'utc', 'created_at': '2026-10-07T02:47:56.391Z'});
    await db.insert('messages', {'id': 'offset', 'created_at': '2026-10-07T10:47:56.391+08:00'});
    await db.insert('messages', {'id': 'local', 'created_at': '2026-10-07T09:07:42.730315'});

    final changed = await LocalDatabaseService.migrateLocalMessageTimesToUtc(db);
    expect(changed, 1);

    final rows = {
      for (final row in await db.query('messages'))
        row['id'] as String: row['created_at'] as String,
    };
    expect(rows['utc'], '2026-10-07T02:47:56.391Z');
    expect(rows['offset'], '2026-10-07T10:47:56.391+08:00');
    expect(
      rows['local'],
      messageCreatedAt(DateTime(2026, 10, 7, 9, 7, 42, 730)),
    );
  });
}

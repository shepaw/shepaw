import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/sync/sync_schema.dart';
import 'package:shepaw/sync/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 同步存储层测试：schema 幂等、触发器 seq 分配、墓碑、changes 分页、
/// adopt 归并、console 落库。用临时文件 sqlite 跑（无插件依赖，默认 CI 可运行）。
///
/// 业务表只建与本测试相关的最小列集，列名与真实 schema 对齐；
/// 真实 v29 迁移的端到端验证见 needs-plugins 集成测试。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var dbCounter = 0;
  Future<Database> openDb() async {
    // ffi 下 ':memory:' 会跨 open 复用，用唯一临时文件保证测试隔离。
    final dir = await Directory.systemTemp.createTemp('sync_store_test');
    final db = await openDatabase(p.join(dir.path, 't${dbCounter++}.db'));
    // 与真实 schema 同列名的最小业务表（sync 相关列由 ensureSyncSchema 补齐）。
    await db.execute(
        'CREATE TABLE agents (id TEXT PRIMARY KEY, name TEXT, created_at INTEGER, updated_at INTEGER)');
    await db.execute(
        'CREATE TABLE channels (id TEXT PRIMARY KEY, name TEXT, created_at TEXT, updated_at TEXT)');
    await db.execute(
        'CREATE TABLE channel_members (id INTEGER PRIMARY KEY AUTOINCREMENT, channel_id TEXT, agent_id TEXT, role TEXT, joined_at TEXT, UNIQUE(channel_id, agent_id))');
    await db.execute(
        'CREATE TABLE messages (id TEXT PRIMARY KEY, channel_id TEXT, content TEXT, created_at TEXT)');
    await db.execute(
        'CREATE TABLE resources (id TEXT PRIMARY KEY, name TEXT, created_at TEXT)');
    await SyncSchema.ensureSyncSchema(db);
    return db;
  }

  group('SyncSchema', () {
    test('ensureSyncSchema 幂等且补齐同步列', () async {
      final db = await openDb();
      await SyncSchema.ensureSyncSchema(db); // 第二次不应报错

      for (final t in ['agents', 'channels', 'channel_members', 'messages', 'resources']) {
        final cols = (await db.rawQuery('PRAGMA table_info($t)'))
            .map((c) => c['name'] as String)
            .toSet();
        expect(cols.contains('seq'), isTrue, reason: '$t 缺 seq 列');
      }
      for (final t in ['messages', 'channel_members', 'resources']) {
        final cols = (await db.rawQuery('PRAGMA table_info($t)'))
            .map((c) => c['name'] as String)
            .toSet();
        expect(cols.contains('updated_at'), isTrue, reason: '$t 缺 updated_at 列');
      }
      for (final t in ['sync_clock', 'sync_devices', 'sync_cursor', 'sync_tombstones']) {
        final rows = await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [t]);
        expect(rows, isNotEmpty, reason: '缺元数据表 $t');
      }
      await db.close();
    });

    test('messages.updated_at 从 created_at 回填', () async {
      final db = await openDb();
      await db.insert('messages', {
        'id': 'm1',
        'channel_id': 'c1',
        'content': 'hi',
        'created_at': '2026-07-20T10:00:00.000Z',
      });
      await SyncSchema.ensureSyncSchema(db);
      final row = (await db.query('messages')).first;
      final expected =
          DateTime.parse('2026-07-20T10:00:00.000Z').millisecondsSinceEpoch;
      expect(row['updated_at'], expected ~/ 1000 * 1000); // strftime 秒级精度
      await db.close();
    });
  });

  group('hub 激活与触发器', () {
    test('存量行回填 seq，新增/更新/删除由触发器分配', () async {
      final db = await openDb();
      final store = SyncStore(db);

      await db.insert('agents',
          {'id': 'a1', 'name': 'A', 'created_at': 1, 'updated_at': 1});
      await db.insert('agents',
          {'id': 'a2', 'name': 'B', 'created_at': 2, 'updated_at': 2});
      await db.insert('messages', {
        'id': 'm1',
        'channel_id': 'c1',
        'content': 'x',
        'created_at': '2026-07-20T10:00:00Z',
      });

      await store.activateHub();

      // 回填：3 行按 rowid 顺序获得 1..3
      expect(await store.currentSeq(), 3);
      final agents = await db.query('agents', orderBy: 'seq ASC');
      expect(agents.map((r) => r['id']), ['a1', 'a2']);

      // 新增 → 触发器分配 4
      await db.insert('agents',
          {'id': 'a3', 'name': 'C', 'created_at': 3, 'updated_at': 3});
      expect(await store.currentSeq(), 4);
      expect((await db.query('agents', where: "id = 'a3'")).first['seq'], 4);

      // 更新 → 恰好 +1（WHEN 守卫防递归）
      await db.update('agents', {'name': 'C2'}, where: "id = 'a3'");
      expect(await store.currentSeq(), 5);
      expect((await db.query('agents', where: "id = 'a3'")).first['seq'], 5);

      // 删除 → 墓碑 +1
      await db.delete('agents', where: "id = 'a1'");
      expect(await store.currentSeq(), 6);
      final tomb = (await db.query('sync_tombstones')).single;
      expect(tomb['table_name'], 'agents');
      expect(tomb['row_key'], 'a1');
      expect(tomb['seq'], 6);

      // 停用后不再分配
      await store.deactivateHub();
      await db.insert('agents',
          {'id': 'a4', 'name': 'D', 'created_at': 4, 'updated_at': 4});
      expect((await db.query('agents', where: "id = 'a4'")).first['seq'], isNull);
      await db.close();
    });

    test('activateHub 幂等：重复调用不重复分配', () async {
      final db = await openDb();
      final store = SyncStore(db);
      await db.insert('agents',
          {'id': 'a1', 'name': 'A', 'created_at': 1, 'updated_at': 1});
      await store.activateHub();
      final seqAfterFirst = await store.currentSeq();
      await store.activateHub();
      expect(await store.currentSeq(), seqAfterFirst);
      await db.close();
    });
  });

  group('changesSince 分页与墓碑', () {
    test('跨表按 seq 升序、limit 分页、含删除墓碑', () async {
      final db = await openDb();
      final store = SyncStore(db);
      await store.activateHub();

      await db.insert('agents',
          {'id': 'a1', 'name': 'A', 'created_at': 1, 'updated_at': 1}); // seq 1
      await db.insert('messages', {
        'id': 'm1',
        'channel_id': 'c1',
        'content': 'x',
        'created_at': '2026-07-20T10:00:00Z',
      }); // seq 2
      await db.delete('agents', where: "id = 'a1'"); // seq 3（墓碑）

      // a1 的行已物理删除，cursor 0 只能看到 messages 的 upsert(seq 2)
      // 和 agents 的墓碑(seq 3)；console 对墓碑做幂等删除，最终态一致。
      final page1 = await store.changesSince(cursor: 0, limit: 1);
      expect(page1.entries.map((e) => e.seq), [2]);
      expect(page1.entries.single.table, 'messages');
      expect(page1.hasMore, isTrue);
      expect(page1.toSeq, 2);

      final page2 = await store.changesSince(cursor: 2, limit: 2);
      expect(page2.entries.single.deleted, isTrue);
      expect(page2.entries.single.key, 'a1');
      expect(page2.entries.single.table, 'agents');
      expect(page2.hasMore, isFalse);

      // tables 载荷分组符合 spec §5.1
      final full = await store.changesSince(cursor: 0, limit: 10);
      final payload = full.tablesPayload();
      expect(payload.keys, containsAll(['agents', 'messages']));
      expect(payload['agents']!.single['deleted'], 1);
      await db.close();
    });

    test('channel_members 传输排除本地自增 id', () async {
      final db = await openDb();
      final store = SyncStore(db);
      await store.activateHub();
      await db.insert('channel_members', {
        'channel_id': 'c1',
        'agent_id': 'a1',
        'role': 'member',
        'joined_at': '2026-07-20T10:00:00Z',
      });
      final page = await store.changesSince(cursor: 0, limit: 10);
      final entry = page.entries.single;
      expect(entry.key, 'c1|a1');
      expect(entry.row!.containsKey('id'), isFalse);
      await db.close();
    });
  });

  group('adopt 归并（hub 侧）', () {
    test('uuid 去重 + updated_at 新者胜 + 重复归并幂等', () async {
      final db = await openDb();
      final store = SyncStore(db);
      await store.activateHub();

      // hub 已有同 uuid 但更旧的 agent
      await db.insert('agents',
          {'id': 'a1', 'name': 'old', 'created_at': 100, 'updated_at': 100});

      final batch = [
        {'id': 'a1', 'name': 'new', 'created_at': 100, 'updated_at': 200},
        {'id': 'a2', 'name': 'fresh', 'created_at': 50, 'updated_at': 50},
      ];
      final (ins1, upd1, skip1) = await store.mergeAdoptBatch('agents', batch);
      expect((ins1, upd1, skip1), (1, 1, 0));
      expect((await db.query('agents', where: "id = 'a1'")).first['name'], 'new');

      // 再来一遍完全相同的批次：全部跳过（本地 updated_at 不更旧）
      final (ins2, upd2, skip2) = await store.mergeAdoptBatch('agents', batch);
      expect((ins2, upd2, skip2), (0, 0, 2));

      // 更旧的上送不覆盖
      final (ins3, upd3, skip3) = await store.mergeAdoptBatch('agents', [
        {'id': 'a1', 'name': 'ancient', 'created_at': 100, 'updated_at': 1},
      ]);
      expect((ins3, upd3, skip3), (0, 0, 1));
      expect((await db.query('agents', where: "id = 'a1'")).first['name'], 'new');
      await db.close();
    });

    test('messages 归并用 created_at 兜底 updated_at', () async {
      final db = await openDb();
      final store = SyncStore(db);
      await store.activateHub();
      final (inserted, _, _) = await store.mergeAdoptBatch('messages', [
        {
          'id': 'm1',
          'channel_id': 'c1',
          'content': 'hello',
          'created_at': '2026-07-20T10:00:00.000Z',
          'updated_at': 0,
        },
      ]);
      expect(inserted, 1);
      final row = (await db.query('messages')).first;
      expect(row['seq'], isNotNull); // 触发器分配
      expect(row['updated_at'], greaterThan(0)); // INSERT 触发器回填
      await db.close();
    });
  });

  group('console 落库', () {
    test('applyChangesPayload upsert + 墓碑删除 + 游标推进 + 重放幂等', () async {
      final db = await openDb();
      final store = SyncStore(db);
      // console 不激活 hub、不装触发器

      final tables = SyncChangeEntry.parseTablesPayload({
        'agents': [
          {
            'key': 'a1',
            'seq': 1,
            'updated_at': 100,
            'deleted': 0,
            'row': {'id': 'a1', 'name': 'A', 'created_at': 1, 'updated_at': 1, 'seq': 1},
          },
        ],
        'channel_members': [
          {
            'key': 'c1|a1',
            'seq': 2,
            'updated_at': 100,
            'deleted': 0,
            'row': {
              'channel_id': 'c1',
              'agent_id': 'a1',
              'role': 'member',
              'joined_at': '2026-07-20T10:00:00Z',
              'seq': 2,
            },
          },
        ],
      });
      await store.applyChangesPayload(tables, 2);
      expect((await db.query('agents')).single['name'], 'A');
      // channel_members 自增 id 由 console 本地生成
      expect((await db.query('channel_members')).single['id'], isNotNull);
      expect((await store.cursorState()).lastAppliedSeq, 2);

      // 重放同批：结果一致
      await store.applyChangesPayload(tables, 2);
      expect((await db.query('agents')).length, 1);
      expect((await db.query('channel_members')).length, 1);

      // 墓碑删除
      final deletes = SyncChangeEntry.parseTablesPayload({
        'agents': [
          {
            'key': 'a1',
            'seq': 3,
            'updated_at': 300,
            'deleted': 1,
            'row': {'id': 'a1'},
          },
        ],
      });
      await store.applyChangesPayload(deletes, 3);
      expect(await db.query('agents'), isEmpty);
      expect((await store.cursorState()).lastAppliedSeq, 3);
      await db.close();
    });
  });
}

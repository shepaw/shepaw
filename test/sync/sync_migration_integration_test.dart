@Tags(['needs-plugins'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/sync/sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 真实 schema 的 v29 迁移端到端验证（path_provider + sqflite harness，
/// 默认 CI 排除，本地以 `flutter test --tags=needs-plugins` 运行）。
void main() {
  late Directory tmpDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // path_provider 走方法通道，指向临时目录。
    tmpDir = await Directory.systemTemp.createTemp('sync_it');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => tmpDir.path,
    );
  });

  test('v29：真实建表链路产出同步列与元数据表', () async {
    final db = await LocalDatabaseService().database;

    // 同步元数据表
    for (final t in [
      'sync_clock',
      'sync_devices',
      'sync_cursor',
      'sync_tombstones'
    ]) {
      final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?", [t]);
      expect(rows, isNotEmpty, reason: '缺元数据表 $t');
    }

    // 业务表 seq 列（真实 schema 全列）
    for (final t in [
      'agents',
      'channels',
      'channel_members',
      'messages',
      'resources'
    ]) {
      final cols = (await db.rawQuery('PRAGMA table_info($t)'))
          .map((c) => c['name'] as String)
          .toSet();
      expect(cols.contains('seq'), isTrue, reason: '$t 缺 seq 列');
    }

    // paired_peers 角色列（PeerStorageService 懒建，先触发 ensureTables）
    await PeerStorageService().ensureTables();
    final peerCols = (await db.rawQuery('PRAGMA table_info(paired_peers)'))
        .map((c) => c['name'] as String)
        .toSet();
    expect(peerCols.contains('device_role'), isTrue);
    expect(peerCols.contains('sync_enabled'), isTrue);
    expect(peerCols.contains('peer_platform'), isTrue);
  });

  test('v29：hub 激活后真实 messages 插入由触发器分配 seq', () async {
    final db = await LocalDatabaseService().database;
    final store = SyncStore(db);
    await store.activateHub();

    final id = 'sync-it-${DateTime.now().microsecondsSinceEpoch}';
    // messages 有外键到 channels；先建 channel 再插消息。
    await db.insert('channels', {
      'id': '$id-ch',
      'name': 'it',
      'type': 'dm',
      'created_at': '2026-07-26T00:00:00Z',
      'updated_at': '2026-07-26T00:00:00Z',
      'created_by': 'it',
    });
    await db.insert('messages', {
      'id': id,
      'channel_id': '$id-ch',
      'sender_id': 'it',
      'sender_type': 'user',
      'sender_name': 'it',
      'content': 'sync integration',
      'created_at': '2026-07-26T00:00:00Z',
    });

    final row =
        (await db.query('messages', where: 'id = ?', whereArgs: [id])).single;
    expect(row['seq'], isNotNull);
    expect(row['updated_at'], greaterThan(0)); // INSERT 触发器从 created_at 回填

    // changesSince 能取到这条真实行
    final page =
        await store.changesSince(cursor: (row['seq'] as int) - 1, limit: 10);
    expect(page.entries.any((e) => e.key == id && e.table == 'messages'),
        isTrue);

    // 清理
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
    await db.delete('channels', where: 'id = ?', whereArgs: ['$id-ch']);
  });
}

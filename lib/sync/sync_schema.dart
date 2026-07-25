import 'package:sqflite/sqflite.dart';

import '../services/logger_service.dart';
import 'sync_tables.dart';

/// 同步层数据库结构（docs/sync_protocol_spec.md §3）。
///
/// - 元数据表：sync_clock / sync_devices / sync_cursor / sync_tombstones，
///   在 onCreate 与 v29 迁移中通过同一 [ensureSyncSchema] 幂等创建。
/// - 业务表改造：为 kSyncTables 中每张表补 `seq`（及缺失的 `updated_at`）列。
/// - `seq` 分配触发器只在设备成为 hub 时安装（[installHubTriggers]），
///   console 永不安装——副本行的 seq 由 hub 帧原样携带。
class SyncSchema {
  SyncSchema._();

  static const _logTag = 'SyncSchema';

  // ---------------------------------------------------------------- 元数据表

  /// 创建同步元数据表 + 业务表同步列（幂等，onCreate/v29 迁移共用）。
  static Future<void> ensureSyncSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_clock (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        next_seq INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_devices (
        peer_id TEXT PRIMARY KEY,
        last_ack_seq INTEGER NOT NULL DEFAULT 0,
        epoch INTEGER NOT NULL DEFAULT 1,
        state TEXT NOT NULL DEFAULT 'active',
        updated_at INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_cursor (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        last_applied_seq INTEGER NOT NULL DEFAULT 0,
        epoch INTEGER NOT NULL DEFAULT 1,
        hub_peer_id TEXT,
        state TEXT NOT NULL DEFAULT 'unpaired'
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_tombstones (
        seq INTEGER PRIMARY KEY,
        table_name TEXT NOT NULL,
        row_key TEXT NOT NULL,
        deleted_at INTEGER NOT NULL
      )
    ''');

    for (final table in kSyncTables) {
      await _addColumnIfMissing(db, table.name, 'seq', 'INTEGER');
      // messages/channel_members/resources 原本没有 updated_at，补上用于
      // adopt 冲突比较；channels/agents 已有（格式分别为 TEXT/INTEGER）。
      if (table.name == 'messages' ||
          table.name == 'channel_members' ||
          table.name == 'resources') {
        await _addColumnIfMissing(
            db, table.name, 'updated_at', 'INTEGER NOT NULL DEFAULT 0');
        await _backfillUpdatedAt(db, table);
      }
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_${table.name}_seq ON ${table.name}(seq)');
    }
  }

  static Future<void> _addColumnIfMissing(
    DatabaseExecutor db,
    String table,
    String column,
    String ddl,
  ) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $ddl');
  }

  /// 用 fallback 时间列（created_at/joined_at，ISO 文本）回填 updated_at 毫秒。
  static Future<void> _backfillUpdatedAt(
      DatabaseExecutor db, SyncTable table) async {
    final fallback = table.fallbackTimeColumn;
    if (fallback == null) return;
    await db.execute('''
      UPDATE ${table.name}
      SET updated_at = COALESCE(CAST(strftime('%s', $fallback) AS INTEGER) * 1000, 0)
      WHERE updated_at = 0
    ''');
  }

  // ---------------------------------------------------------------- hub 触发器

  /// 安装 hub 侧触发器：任何业务写自动分配 seq，删除落墓碑。
  ///
  /// AFTER UPDATE 的 `WHEN NEW.seq = OLD.seq` 守卫使触发器内部的 seq 回写
  /// 不会递归；hub 归并（INSERT/UPDATE）也因此自动获得 seq。
  static Future<void> installHubTriggers(DatabaseExecutor db) async {
    for (final table in kSyncTables) {
      final name = table.name;
      final keyExpr = table.keyColumns.length == 1
          ? 'OLD.${table.keyColumns.first}'
          : table.keyColumns.map((c) => 'OLD.$c').join(" || '|' || ");

      // messages 的 updated_at 由 INSERT 触发器从 created_at 回填（DAO 不知道
      // 新列）；UPDATE 不刷新 updated_at，保持 adopt 归并语义的保真度。
      final insertExtra = name == 'messages'
          ? ", updated_at = CASE WHEN $name.updated_at = 0 THEN COALESCE(CAST(strftime('%s', NEW.created_at) AS INTEGER) * 1000, 0) ELSE $name.updated_at END"
          : '';

      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS sync_${name}_ai AFTER INSERT ON $name BEGIN
          UPDATE sync_clock SET next_seq = next_seq + 1 WHERE id = 1;
          UPDATE $name SET seq = (SELECT next_seq FROM sync_clock WHERE id = 1)$insertExtra
          WHERE rowid = NEW.rowid;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS sync_${name}_au AFTER UPDATE ON $name
        WHEN NEW.seq = OLD.seq BEGIN
          UPDATE sync_clock SET next_seq = next_seq + 1 WHERE id = 1;
          UPDATE $name SET seq = (SELECT next_seq FROM sync_clock WHERE id = 1)
          WHERE rowid = NEW.rowid;
        END
      ''');
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS sync_${name}_ad AFTER DELETE ON $name BEGIN
          UPDATE sync_clock SET next_seq = next_seq + 1 WHERE id = 1;
          INSERT INTO sync_tombstones (seq, table_name, row_key, deleted_at)
          VALUES (
            (SELECT next_seq FROM sync_clock WHERE id = 1),
            '$name',
            $keyExpr,
            CAST(strftime('%s', 'now') AS INTEGER) * 1000
          );
        END
      ''');
    }
    LoggerService().info('hub sync triggers installed', tag: _logTag);
  }

  /// 摘除 hub 触发器（角色降级/停用时）。幂等。
  static Future<void> dropHubTriggers(DatabaseExecutor db) async {
    for (final table in kSyncTables) {
      for (final suffix in const ['ai', 'au', 'ad']) {
        await db.execute(
            'DROP TRIGGER IF EXISTS sync_${table.name}_$suffix');
      }
    }
    LoggerService().info('hub sync triggers dropped', tag: _logTag);
  }
}

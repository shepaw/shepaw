import 'package:sqflite/sqflite.dart';

import 'sync_schema.dart';
import 'sync_tables.dart';

/// 一条变更记录（changes 帧的元素，spec §5.1）。
class SyncChangeEntry {
  SyncChangeEntry({
    required this.table,
    required this.key,
    required this.seq,
    required this.updatedAtMs,
    required this.deleted,
    this.row,
  });

  /// 来源表名。帧内按表分组，不上线序列化。
  final String table;

  /// 身份键（多列用 '|' 连接，见 SyncTable.keyOf）。
  final String key;
  final int seq;
  final int updatedAtMs;
  final bool deleted;

  /// upsert 时为整行（含 seq，已排除 transferOmitColumns）；
  /// deleted 时只含身份键列。
  final Map<String, Object?>? row;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'seq': seq,
        'updated_at': updatedAtMs,
        'deleted': deleted ? 1 : 0,
        if (row != null) 'row': row,
      };

  static SyncChangeEntry fromJson(String table, Map<String, dynamic> json) =>
      SyncChangeEntry(
        table: table,
        key: json['key'] as String,
        seq: json['seq'] as int,
        updatedAtMs: json['updated_at'] as int? ?? 0,
        deleted: json['deleted'] == 1,
        row: (json['row'] as Map?)?.cast<String, Object?>(),
      );

  /// 解析 spec §5.1 changes 帧的 tables 载荷。
  static Map<String, List<SyncChangeEntry>> parseTablesPayload(
      Map<String, dynamic> tables) {
    return tables.map((name, list) => MapEntry(
          name,
          (list as List)
              .map((e) =>
                  SyncChangeEntry.fromJson(name, (e as Map).cast<String, dynamic>()))
              .toList(),
        ));
  }
}

/// changes 帧分页结果。
class SyncChangesPage {
  SyncChangesPage({
    required this.entries,
    required this.hasMore,
    required this.fromSeq,
    required this.toSeq,
  });

  /// 按 seq 全局升序（跨表合并后）。
  final List<SyncChangeEntry> entries;
  final bool hasMore;
  final int fromSeq;
  final int toSeq; // entries 中最大 seq；空页 = fromSeq

  /// 按表分组为 spec §5.1 的 tables 载荷。
  Map<String, List<Map<String, dynamic>>> tablesPayload() {
    final tables = <String, List<Map<String, dynamic>>>{};
    for (final e in entries) {
      tables.putIfAbsent(e.table, () => []).add(e.toJson());
    }
    return tables;
  }
}

/// hub 侧一台 console 的同步状态。
class SyncDeviceInfo {
  SyncDeviceInfo({
    required this.peerId,
    required this.lastAckSeq,
    required this.epoch,
    required this.state,
    required this.updatedAtMs,
  });

  final String peerId;
  final int lastAckSeq;
  final int epoch;
  final String state;
  final int updatedAtMs;

  static SyncDeviceInfo fromRow(Map<String, Object?> r) => SyncDeviceInfo(
        peerId: r['peer_id'] as String,
        lastAckSeq: r['last_ack_seq'] as int,
        epoch: r['epoch'] as int,
        state: r['state'] as String,
        updatedAtMs: r['updated_at'] as int,
      );
}

/// console 侧本地游标状态（配对状态机持久化，spec §2.4）。
class SyncCursorState {
  SyncCursorState({
    required this.lastAppliedSeq,
    required this.epoch,
    this.hubPeerId,
    required this.state,
  });

  final int lastAppliedSeq;
  final int epoch;
  final String? hubPeerId;
  final String state;

  static const stateUnpaired = 'unpaired';
  static const stateRoleNegotiated = 'role_negotiated';
  static const stateAdopting = 'adopting';
  static const stateSnapshotSync = 'snapshot_sync';
  static const stateActive = 'active';

  static SyncCursorState initial() => SyncCursorState(
        lastAppliedSeq: 0,
        epoch: 1,
        state: stateUnpaired,
      );
}

/// 同步存储访问层。包一层 LocalDatabaseService 的 db 句柄，
/// hub 与 console 两侧共用的查询都收敛在这里，帧处理器不直接写 SQL。
class SyncStore {
  SyncStore(this._db);

  final Database _db;

  // ------------------------------------------------------------------ clock

  /// 当前 seq 水位（未激活 hub 时为 0）。
  Future<int> currentSeq() async {
    final rows =
        await _db.rawQuery('SELECT next_seq FROM sync_clock WHERE id = 1');
    if (rows.isEmpty) return 0;
    return rows.first['next_seq'] as int;
  }

  // ---------------------------------------------------------- hub 激活/停用

  /// 设备成为 hub：初始化时钟 → 回填存量行 seq（rowid 顺序）→ 装触发器。
  /// 幂等；重复调用不会重复分配（已有序号的行跳过）。
  Future<void> activateHub() async {
    await _db.transaction((txn) async {
      await txn.insert(
        'sync_clock',
        <String, Object?>{'id': 1, 'next_seq': 0},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      for (final table in kSyncTables) {
        final pending = await txn.query(table.name,
            columns: <String>['rowid'],
            where: 'seq IS NULL',
            orderBy: 'rowid ASC');
        for (final row in pending) {
          await txn.rawUpdate(
              'UPDATE sync_clock SET next_seq = next_seq + 1 WHERE id = 1');
          final seq = (await txn.rawQuery(
                  'SELECT next_seq FROM sync_clock WHERE id = 1'))
              .first['next_seq'] as int;
          await txn.rawUpdate('UPDATE ${table.name} SET seq = ? WHERE rowid = ?',
              <Object?>[seq, row['rowid']]);
        }
      }
    });
    // 触发器在回填完成后安装，避免回填自身产生触发器噪音。
    await SyncSchema.installHubTriggers(_db);
  }

  /// 设备不再是 hub（M6 降级路径；M1 仅用于测试与防御）。
  Future<void> deactivateHub() => SyncSchema.dropHubTriggers(_db);

  // ------------------------------------------------------- changes 查询(hub)

  /// 拉取 cursor 之后的变更，跨表按 seq 升序合并，至多 limit 条。
  Future<SyncChangesPage> changesSince({
    required int cursor,
    required int limit,
  }) async {
    final entries = <SyncChangeEntry>[];

    for (final table in kSyncTables) {
      final rows = await _db.query(table.name,
          where: 'seq IS NOT NULL AND seq > ?',
          whereArgs: <Object?>[cursor],
          orderBy: 'seq ASC',
          limit: limit);
      for (final row in rows) {
        final transferRow = Map<String, Object?>.of(row)
          ..removeWhere((k, _) => table.transferOmitColumns.contains(k));
        entries.add(SyncChangeEntry(
          table: table.name,
          key: table.keyOf(row),
          seq: row['seq'] as int,
          updatedAtMs: table.updatedAtMsOf(row),
          deleted: false,
          row: transferRow,
        ));
      }
    }

    final tombstones = await _db.query('sync_tombstones',
        where: 'seq > ?',
        whereArgs: <Object?>[cursor],
        orderBy: 'seq ASC',
        limit: limit);
    for (final t in tombstones) {
      final table = syncTableByName(t['table_name'] as String);
      final keyParts = (t['row_key'] as String).split('|');
      entries.add(SyncChangeEntry(
        table: table.name,
        key: t['row_key'] as String,
        seq: t['seq'] as int,
        updatedAtMs: t['deleted_at'] as int,
        deleted: true,
        row: <String, Object?>{
          for (var i = 0; i < table.keyColumns.length; i++)
            table.keyColumns[i]: keyParts[i],
        },
      ));
    }

    entries.sort((a, b) => a.seq.compareTo(b.seq));
    final page = entries.take(limit).toList();
    return SyncChangesPage(
      entries: page,
      hasMore: entries.length > limit,
      fromSeq: cursor + 1,
      toSeq: page.isEmpty ? cursor : page.last.seq,
    );
  }

  // ------------------------------------------------------------ devices(hub)

  Future<void> upsertDevice(
    String peerId, {
    int? lastAckSeq,
    String? state,
    int epoch = 1,
  }) async {
    await _db.insert(
      'sync_devices',
      <String, Object?>{
        'peer_id': peerId,
        'last_ack_seq': lastAckSeq ?? 0,
        'epoch': epoch,
        'state': state ?? SyncCursorState.stateActive,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateDeviceAck(String peerId, int seq) async {
    await _db.update(
      'sync_devices',
      <String, Object?>{
        'last_ack_seq': seq,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'peer_id = ?',
      whereArgs: <Object?>[peerId],
    );
  }

  Future<void> updateDeviceState(String peerId, String state) async {
    await _db.update(
      'sync_devices',
      <String, Object?>{
        'state': state,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'peer_id = ?',
      whereArgs: <Object?>[peerId],
    );
  }

  Future<void> removeDevice(String peerId) async {
    await _db.delete('sync_devices',
        where: 'peer_id = ?', whereArgs: <Object?>[peerId]);
  }

  Future<List<SyncDeviceInfo>> devices() async {
    final rows = await _db.query('sync_devices');
    return rows.map(SyncDeviceInfo.fromRow).toList();
  }

  // ------------------------------------------------------------ cursor(console)

  Future<SyncCursorState> cursorState() async {
    final rows = await _db.query('sync_cursor', where: 'id = 1');
    if (rows.isEmpty) return SyncCursorState.initial();
    final r = rows.first;
    return SyncCursorState(
      lastAppliedSeq: r['last_applied_seq'] as int,
      epoch: r['epoch'] as int,
      hubPeerId: r['hub_peer_id'] as String?,
      state: r['state'] as String,
    );
  }

  Future<void> writeCursor({
    int? lastAppliedSeq,
    int? epoch,
    String? hubPeerId,
    String? state,
  }) async {
    final current = await cursorState();
    await _db.insert(
      'sync_cursor',
      <String, Object?>{
        'id': 1,
        'last_applied_seq': lastAppliedSeq ?? current.lastAppliedSeq,
        'epoch': epoch ?? current.epoch,
        'hub_peer_id': hubPeerId ?? current.hubPeerId,
        'state': state ?? current.state,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ------------------------------------------------------- 变更落库(console)

  /// console 侧应用一帧 changes 载荷：单事务逐表 upsert/删除，
  /// 成功后推进游标。INSERT OR REPLACE 幂等，重放同一批次无副作用（spec §5.1）。
  Future<void> applyChangesPayload(
    Map<String, List<SyncChangeEntry>> tables,
    int toSeq,
  ) async {
    await _db.transaction((txn) async {
      for (final e in tables.entries) {
        final table = syncTableByName(e.key);
        for (final entry in e.value) {
          _applyEntry(txn, table, entry);
        }
      }
      final current = await txn
          .query('sync_cursor', where: 'id = 1')
          .then((rows) => rows.isEmpty ? null : rows.first);
      await txn.insert(
        'sync_cursor',
        <String, Object?>{
          'id': 1,
          'last_applied_seq': toSeq,
          'epoch': current?['epoch'] ?? 1,
          'hub_peer_id': current?['hub_peer_id'],
          'state': SyncCursorState.stateActive,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  void _applyEntry(Transaction txn, SyncTable table, SyncChangeEntry entry) {
    if (entry.deleted) {
      final keyRow = entry.row!;
      txn.delete(
        table.name,
        where: table.keyColumns.map((c) => '$c = ?').join(' AND '),
        whereArgs: table.keyColumns.map((c) => keyRow[c]).toList(),
      );
      return;
    }
    final row = Map<String, Object?>.of(entry.row!)
      ..removeWhere((k, _) => table.transferOmitColumns.contains(k));
    txn.insert(
      table.name,
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // --------------------------------------------------------- adopt 归并(hub)

  /// 手机本地业务表是否非空（决定是否进入 adopting 阶段）。
  Future<bool> hasLocalBusinessData() async {
    for (final table in kSyncTables) {
      final rows =
          await _db.rawQuery('SELECT 1 FROM ${table.name} LIMIT 1');
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  /// 读取一张表的全部行用于 adopt 导出。
  Future<List<Map<String, Object?>>> exportTable(String tableName) async {
    final rows = await _db.query(tableName);
    return rows.map((r) => Map<String, Object?>.of(r)).toList();
  }

  /// hub 归并一批 adopt 行：uuid 去重 + updated_at 新者胜（spec §6）。
  /// 触发器自动为新行/被更新行分配 seq。返回 (插入数, 更新数, 跳过数)。
  Future<(int, int, int)> mergeAdoptBatch(
    String tableName,
    List<Map<String, Object?>> rows,
  ) async {
    final table = syncTableByName(tableName);
    var inserted = 0, updated = 0, skipped = 0;
    await _db.transaction((txn) async {
      for (final incoming in rows) {
        final row = Map<String, Object?>.of(incoming)
          ..remove('seq') // hub 重新分配
          ..removeWhere((k, _) => table.transferOmitColumns.contains(k));
        final where = table.keyColumns.map((c) => '$c = ?').join(' AND ');
        final whereArgs = table.keyColumns.map((c) => row[c]).toList();
        final existing = await txn.query(table.name,
            where: where, whereArgs: whereArgs, limit: 1);
        if (existing.isEmpty) {
          await txn.insert(table.name, row);
          inserted++;
          continue;
        }
        final localMs = table.updatedAtMsOf(existing.first);
        final incomingMs = table.updatedAtMsOf(row);
        if (incomingMs > localMs) {
          final nonKeyCols = Map<String, Object?>.of(row)
            ..removeWhere((k, _) => table.keyColumns.contains(k));
          await txn.update(table.name, nonKeyCols,
              where: where, whereArgs: whereArgs);
          updated++;
        } else {
          skipped++;
        }
      }
    });
    return (inserted, updated, skipped);
  }

  /// console 收到 adopt.done 后清空本地业务表（此前已自行导出备份）。
  Future<void> clearBusinessTables() async {
    await _db.transaction((txn) async {
      for (final table in kSyncTables.reversed) {
        await txn.delete(table.name);
      }
    });
  }

  /// 快照导入（spec §7）：ATTACH 快照库，按表替换业务表内容，
  /// 并把游标推进到快照水位。console 侧无触发器，行内 seq 原样保留。
  ///
  /// 只导入同步表——快照文件中 hub 的 paired_peers/user 等表绝不覆盖本机数据。
  Future<void> importSnapshotTables(String snapshotPath, int watermark) async {
    await _db.execute('ATTACH DATABASE ? AS snap', <Object?>[snapshotPath]);
    try {
      await _db.transaction((txn) async {
        for (final table in kSyncTables) {
          // 列清单以本机 schema 为准（两侧同为 v29），排除本地自增列。
          final cols = (await txn.rawQuery('PRAGMA table_info(${table.name})'))
              .map((c) => c['name'] as String)
              .where((c) => !table.transferOmitColumns.contains(c))
              .toList();
          final colList = cols.join(', ');
          await txn.delete(table.name);
          await txn.execute(
              'INSERT INTO ${table.name} ($colList) SELECT $colList FROM snap.${table.name}');
        }
        final current = await txn
            .query('sync_cursor', where: 'id = 1')
            .then((rows) => rows.isEmpty ? null : rows.first);
        await txn.insert(
          'sync_cursor',
          <String, Object?>{
            'id': 1,
            'last_applied_seq': watermark,
            'epoch': current?['epoch'] ?? 1,
            'hub_peer_id': current?['hub_peer_id'],
            'state': SyncCursorState.stateActive,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });
    } finally {
      await _db.execute('DETACH DATABASE snap');
    }
  }

  // ------------------------------------------------------------------ stats

  /// 主库文件大小（字节）。
  Future<int> dbBytes() async {
    final pageCount = (await _db.rawQuery('PRAGMA page_count'))
        .first
        .values
        .first as int;
    final pageSize =
        (await _db.rawQuery('PRAGMA page_size')).first.values.first as int;
    return pageCount * pageSize;
  }
}

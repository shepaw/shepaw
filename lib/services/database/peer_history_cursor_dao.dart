import 'package:sqflite/sqflite.dart';

import '../local_database_service.dart';

/// 一个本地 channel 上次同步会话历史时记下的游标。
class PeerHistoryCursorEntry {
  final String channelId;
  final String remoteSessionId;
  final String cursor;
  final int total;
  final int updatedAt;

  const PeerHistoryCursorEntry({
    required this.channelId,
    required this.remoteSessionId,
    required this.cursor,
    required this.total,
    required this.updatedAt,
  });

  Map<String, Object?> toMap() => {
        'channel_id': channelId,
        'remote_session_id': remoteSessionId,
        'cursor': cursor,
        'total': total,
        'updated_at': updatedAt,
      };

  factory PeerHistoryCursorEntry.fromMap(Map<String, Object?> map) {
    return PeerHistoryCursorEntry(
      channelId: map['channel_id'] as String? ?? '',
      remoteSessionId: map['remote_session_id'] as String? ?? '',
      cursor: map['cursor'] as String? ?? '',
      total: map['total'] as int? ?? 0,
      updatedAt: map['updated_at'] as int? ?? 0,
    );
  }
}

/// 会话历史游标。删 channel、清空消息或 [LocalDatabaseService.clearAllData] 时要一起删。
extension PeerHistoryCursorDao on LocalDatabaseService {
  Future<PeerHistoryCursorEntry?> getPeerHistoryCursor(String channelId) async {
    final db = await database;
    final rows = await db.query(
      'peer_history_cursor',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PeerHistoryCursorEntry.fromMap(rows.first);
  }

  Future<void> upsertPeerHistoryCursor(PeerHistoryCursorEntry entry) async {
    final db = await database;
    await db.insert(
      'peer_history_cursor',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deletePeerHistoryCursor(String channelId) async {
    final db = await database;
    await db.delete(
      'peer_history_cursor',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
  }

  /// 远端 session id → 上次同步完成时的 `total`。
  Future<Map<String, int>> peerHistoryCursorTotalsByRemoteSession() async {
    final db = await database;
    final rows = await db.query(
      'peer_history_cursor',
      columns: const ['remote_session_id', 'total'],
    );
    final totals = <String, int>{};
    for (final row in rows) {
      final id = row['remote_session_id'] as String?;
      final total = row['total'] as int?;
      if (id == null || id.isEmpty || total == null) continue;
      // 同一个远端会话可能同时对应 `psess_` 和旧 channel。取较小的 total，
      // 宁可多同步一次，也不要因为较大的那条把会话判成已经对齐。
      final previous = totals[id];
      if (previous == null || total < previous) totals[id] = total;
    }
    return totals;
  }
}

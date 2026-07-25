import 'package:sqflite/sqflite.dart';
import '../local_database_service.dart';
import '../session/history_compaction_cache.dart';

/// DAO for per-channel history compaction summaries.
extension HistoryCompactionCacheDao on LocalDatabaseService {
  Future<HistoryCompactionCacheEntry?> getHistoryCompactionCache(
    String channelId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'history_compaction_cache',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return HistoryCompactionCacheEntry.fromMap(rows.first);
  }

  Future<void> upsertHistoryCompactionCache(
    HistoryCompactionCacheEntry entry,
  ) async {
    final db = await database;
    await db.insert(
      'history_compaction_cache',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteHistoryCompactionCache(String channelId) async {
    final db = await database;
    await db.delete(
      'history_compaction_cache',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
  }
}

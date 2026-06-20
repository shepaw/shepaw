import 'package:sqflite/sqflite.dart';

import '../local_database_service.dart';

/// 同步专用数据访问（messages / channels / index / cursor）。
extension SyncDao on LocalDatabaseService {
  Future<List<Map<String, dynamic>>> getMessagesCreatedSince({
    required int sinceMs,
    String? channelId,
    int limit = 50,
  }) async {
    final db = await database;
    final sinceIso = DateTime.fromMillisecondsSinceEpoch(sinceMs).toIso8601String();
    if (channelId != null) {
      return db.query(
        'messages',
        where: 'created_at > ? AND channel_id = ?',
        whereArgs: [sinceIso, channelId],
        orderBy: 'created_at ASC',
        limit: limit,
      );
    }
    return db.query(
      'messages',
      where: 'created_at > ?',
      whereArgs: [sinceIso],
      orderBy: 'created_at ASC',
      limit: limit,
    );
  }

  Future<void> upsertMessageFromSync(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert(
      'messages',
      {
        'id': row['id'],
        'channel_id': row['channel_id'],
        'sender_id': row['sender_id'],
        'sender_type': row['sender_type'] ?? 'user',
        'sender_name': row['sender_name'] ?? '',
        'content': row['content'] ?? '',
        'message_type': row['message_type'] ?? 'text',
        'metadata': row['metadata'],
        'reply_to_id': row['reply_to_id'],
        'created_at': row['created_at'],
        'is_read': row['is_read'] ?? 0,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<Map<String, dynamic>>> getChannelsUpdatedSince(int sinceMs, {int limit = 50}) async {
    final db = await database;
    final sinceIso = DateTime.fromMillisecondsSinceEpoch(sinceMs).toIso8601String();
    return db.query(
      'channels',
      where: 'updated_at > ? OR created_at > ?',
      whereArgs: [sinceIso, sinceIso],
      orderBy: 'updated_at ASC',
      limit: limit,
    );
  }

  Future<void> upsertChannelFromSync(Map<String, dynamic> row) async {
    final db = await database;
    await db.insert(
      'channels',
      {
        'id': row['id'],
        'name': row['name'] ?? '',
        'description': row['description'],
        'type': row['type'] ?? 'dm',
        'avatar_path': row['avatar_path'],
        'is_private': row['is_private'] ?? 0,
        'parent_group_id': row['parent_group_id'],
        'system_prompt': row['system_prompt'],
        'max_loop_rounds': row['max_loop_rounds'],
        'mention_mode': row['mention_mode'],
        'planning_mode': row['planning_mode'] ?? 0,
        'flow_mode': row['flow_mode'] ?? 0,
        'created_at': row['created_at'],
        'updated_at': row['updated_at'] ?? row['created_at'],
        'created_by': row['created_by'] ?? 'sync',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> upsertMessageIndex({
    required String messageId,
    required String channelId,
    required int wallTime,
    required String preview,
    required String senderName,
    required bool hasAttachment,
  }) async {
    final db = await database;
    await db.insert(
      'identity_message_index',
      {
        'message_id': messageId,
        'channel_id': channelId,
        'wall_time': wallTime,
        'preview': preview,
        'sender_name': senderName,
        'has_attachment': hasAttachment ? 1 : 0,
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> countCachedMessages() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COUNT(*) as c FROM messages');
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> trimMessagesToPolicy(int maxMessages, int maxDays) async {
    final db = await database;
    if (maxDays > 0) {
      final cutoff = DateTime.now().subtract(Duration(days: maxDays)).toIso8601String();
      await db.delete('messages', where: 'created_at < ?', whereArgs: [cutoff]);
    }
    if (maxMessages <= 0) return;
    final count = await countCachedMessages();
    if (count <= maxMessages) return;
    final excess = count - maxMessages;
    final old = await db.query(
      'messages',
      columns: ['id'],
      orderBy: 'created_at ASC',
      limit: excess,
    );
    for (final row in old) {
      await db.delete('messages', where: 'id = ?', whereArgs: [row['id']]);
    }
  }

  Future<void> clearOwnedDevices() async {
    final db = await database;
    await db.delete('identity_owned_devices');
  }

  // ── Blob cache (App 设备附件 LRU) ─────────────────────────────────────────

  Future<void> upsertBlobCacheEntry({
    required String blobKey,
    required String relativePath,
    required String sha256,
    required int sizeBytes,
    String? mimeType,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'identity_blob_cache',
      {
        'blob_key': blobKey,
        'relative_path': relativePath,
        'sha256': sha256,
        'size_bytes': sizeBytes,
        'mime_type': mimeType,
        'cached_at': now,
        'last_access_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchBlobCacheAccess(String blobKey) async {
    final db = await database;
    await db.update(
      'identity_blob_cache',
      {'last_access_at': DateTime.now().millisecondsSinceEpoch},
      where: 'blob_key = ?',
      whereArgs: [blobKey],
    );
  }

  Future<Map<String, dynamic>?> getBlobCacheEntry(String blobKey) async {
    final db = await database;
    final rows = await db.query('identity_blob_cache', where: 'blob_key = ?', whereArgs: [blobKey], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> totalBlobCacheBytes() async {
    final db = await database;
    final r = await db.rawQuery('SELECT COALESCE(SUM(size_bytes), 0) as t FROM identity_blob_cache');
    return (r.first['t'] as int?) ?? 0;
  }

  Future<List<Map<String, dynamic>>> listBlobCacheEntriesOldestFirst() async {
    final db = await database;
    return db.query('identity_blob_cache', orderBy: 'last_access_at ASC');
  }

  Future<void> deleteBlobCacheEntry(String blobKey) async {
    final db = await database;
    await db.delete('identity_blob_cache', where: 'blob_key = ?', whereArgs: [blobKey]);
  }
}

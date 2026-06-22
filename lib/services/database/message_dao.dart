import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../../identity/services/sync_local_write_hook.dart';
import '../../identity/services/sync_message_fetch_service.dart';

/// 消息（含流式/部分消息）相关的数据访问层。
extension MessageDao on LocalDatabaseService {
  /// 创建消息
  Future<void> createMessage({
    required String id,
    required String channelId,
    required String senderId,
    required String senderType,
    required String senderName,
    required String content,
    String messageType = 'text',
    Map<String, dynamic>? metadata,
    String? replyToId,
  }) async {
    final db = await database;
    final createdAt = DateTime.now().toIso8601String();
    await db.insert(
      'messages',
      {
        'id': id,
        'channel_id': channelId,
        'sender_id': senderId,
        'sender_type': senderType,
        'sender_name': senderName,
        'content': content,
        'message_type': messageType,
        'metadata': metadata != null ? jsonEncode(metadata) : null,
        'reply_to_id': replyToId,
        'created_at': createdAt,
        'updated_at': createdAt,
        'is_read': 0,
      },
    );
    SyncLocalWriteHook.onMessageCreated(
      id: id,
      channelId: channelId,
      senderId: senderId,
      senderType: senderType,
      senderName: senderName,
      content: content,
      messageType: messageType,
      metadata: metadata != null ? jsonEncode(metadata) : null,
      replyToId: replyToId,
      createdAt: createdAt,
    );
  }

  /// 获取 Channel 的消息
  Future<List<Map<String, dynamic>>> getChannelMessages(String channelId, {int limit = 100, int offset = 0}) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// 根据 ID 获取单条消息（App 可自动从 Primary 按需拉取正文）。
  Future<Map<String, dynamic>?> getMessageById(String messageId, {bool fetchRemote = true}) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (results.isNotEmpty) return results.first;
    if (!fetchRemote) return null;
    return SyncMessageFetchService.instance.fetchMessageBody(messageId);
  }

  /// 标记消息为已读
  Future<void> markMessageAsRead(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
  }

  /// 删除消息
  Future<void> deleteMessage(String messageId) async {
    final db = await database;
    final existing = await getMessageById(messageId, fetchRemote: false);
    final channelId = existing?['channel_id'] as String? ?? '';
    await db.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (channelId.isNotEmpty) {
      SyncLocalWriteHook.onMessageDeleted(messageId: messageId, channelId: channelId);
    }
  }

  /// 统计 channel 中 created_at >= [createdAt] 的消息数量（含该时间点）。
  Future<int> countMessagesFromTimestamp(String channelId, String createdAt) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE channel_id = ? AND created_at >= ?',
      [channelId, createdAt],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 获取消息的 created_at 值
  Future<String?> getMessageCreatedAt(String messageId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      columns: ['created_at'],
      where: 'id = ?',
      whereArgs: [messageId],
    );
    return results.isEmpty ? null : results.first['created_at'] as String?;
  }

  /// 删除指定 channel 中某个时间戳及之后的所有消息
  Future<void> deleteMessagesFromTimestamp(String channelId, String createdAt) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: 'channel_id = ? AND created_at >= ?',
      whereArgs: [channelId, createdAt],
    );
    await db.delete(
      'messages',
      where: 'channel_id = ? AND created_at >= ?',
      whereArgs: [channelId, createdAt],
    );
    for (final row in rows) {
      final messageId = row['id'] as String?;
      if (messageId == null) continue;
      await SyncLocalWriteHook.onMessageDeleted(
        messageId: messageId,
        channelId: channelId,
      );
    }
  }

  /// 获取 Channel 中文本消息的总数
  Future<int> getChannelMessageCount(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM messages WHERE channel_id = ? AND message_type = 'text'",
      [channelId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 删除 Channel 的所有消息
  Future<void> deleteChannelMessages(String channelId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    await db.delete(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    for (final row in rows) {
      final messageId = row['id'] as String?;
      if (messageId == null) continue;
      await SyncLocalWriteHook.onMessageDeleted(
        messageId: messageId,
        channelId: channelId,
      );
    }
  }

  /// 更新消息内容
  Future<void> updateMessage({
    required String messageId,
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    final existing = await getMessageById(messageId);
    final updatedAt = DateTime.now().toIso8601String();
    final updateData = <String, dynamic>{
      'content': content,
      'updated_at': updatedAt,
    };

    if (metadata != null) {
      updateData['metadata'] = jsonEncode(metadata);
    }

    await db.update(
      'messages',
      updateData,
      where: 'id = ?',
      whereArgs: [messageId],
    );

    if (existing != null) {
      SyncLocalWriteHook.onMessageUpdated(
        messageId: messageId,
        channelId: existing['channel_id'] as String? ?? '',
        content: content,
        metadata: metadata != null ? jsonEncode(metadata) : null,
        updatedAt: updatedAt,
      );
    }
  }

  Future<void> updateMessageMetadata(String messageId, Map<String, dynamic> metadata) async {
    final db = await database;
    final existing = await getMessageById(messageId);
    final updatedAt = DateTime.now().toIso8601String();
    await db.update(
      'messages',
      {'metadata': jsonEncode(metadata), 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (existing != null) {
      SyncLocalWriteHook.onMessageUpdated(
        messageId: messageId,
        channelId: existing['channel_id'] as String? ?? '',
        content: existing['content'] as String? ?? '',
        metadata: jsonEncode(metadata),
        updatedAt: updatedAt,
      );
    }
  }

  /// Create or update a partial streaming message.
  /// 
  /// If [existingMessageId] is provided, updates that message with new content.
  /// Otherwise, creates a new message record.
  /// 
  /// All partial messages are marked with `status: 'streaming'` in metadata
  /// and tagged with `is_recoverable: true` for UI recovery on app restart.
  Future<String> upsertPartialStreamingMessage({
    required String? existingMessageId,
    required String channelId,
    required String senderId,
    required String senderName,
    required String content,
    required String? replyToId,
    String status = 'streaming',
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    final messageId = existingMessageId ?? const Uuid().v4();
    final now = DateTime.now().toIso8601String();

    metadata ??= {};
    metadata['status'] = status;
    metadata['streaming_flushed_at'] = now;
    metadata['is_recoverable'] = true;
    
    // Include trace ID if available
    if (metadata['trace_id'] == null) {
      metadata['trace_id'] = 'trace_$messageId';
    }

    final values = {
      'id': messageId,
      'channel_id': channelId,
      'sender_id': senderId,
      'sender_type': 'agent',
      'sender_name': senderName,
      'content': content,
      'message_type': 'text',
      'metadata': jsonEncode(metadata),
      'reply_to_id': replyToId,
      'created_at': now,
      'is_read': 0,
    };

    try {
      if (existingMessageId != null) {
        // Update existing partial message
        await db.update(
          'messages',
          {
            'content': content,
            'metadata': jsonEncode(metadata),
          },
          where: 'id = ?',
          whereArgs: [messageId],
        );
        LoggerService().debug(
          'Updated partial streaming message: $messageId (${content.length} chars)',
          tag: 'LocalDatabaseService',
        );
      } else {
        // Create new partial message
        await db.insert('messages', values);
        LoggerService().debug(
          'Created partial streaming message: $messageId (${content.length} chars)',
          tag: 'LocalDatabaseService',
        );
      }
    } catch (e, st) {
      LoggerService().error(
        'Failed to upsert partial streaming message',
        tag: 'LocalDatabaseService',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }

    return messageId;
  }

  /// Mark a message as interrupted.
  /// 
  /// Updates the message status to 'partial' and records the interruption reason
  /// and timestamp in metadata for diagnostic purposes.
  /// 
  /// [interruptionReason] should be one of:
  ///   - 'connection_lost': Network disconnection
  ///   - 'user_cancelled': User explicitly cancelled
  ///   - 'task_error': Error in agent processing
  ///   - 'timeout': Task exceeded timeout
  ///   - 'app_backgrounded': App moved to background
  Future<void> markMessageInterrupted({
    required String messageId,
    required String interruptionReason,
  }) async {
    final db = await database;
    try {
      final result = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );

      if (result.isEmpty) {
        LoggerService().warning(
          'Cannot mark message as interrupted: message not found ($messageId)',
          tag: 'LocalDatabaseService',
        );
        return;
      }

      final msg = result.first;
      final metadata =
          jsonDecode(msg['metadata'] as String? ?? '{}') as Map<String, dynamic>;

      metadata['status'] = 'partial';
      metadata['interruption_reason'] = interruptionReason;
      metadata['interrupted_at'] = DateTime.now().toIso8601String();

      await db.update(
        'messages',
        {'metadata': jsonEncode(metadata)},
        where: 'id = ?',
        whereArgs: [messageId],
      );

      LoggerService().info(
        'Marked message as interrupted: $messageId (reason: $interruptionReason)',
        tag: 'LocalDatabaseService',
      );
    } catch (e, st) {
      LoggerService().error(
        'Failed to mark message as interrupted',
        tag: 'LocalDatabaseService',
        error: e,
        stackTrace: st,
      );
      // Don't rethrow — this is best-effort marking
    }
  }

  /// Mark a partial message as completed.
  /// 
  /// Called when a streaming task finishes successfully.
  /// Updates the partial message to `status: 'completed'` and optionally
  /// updates content if new content was accumulated after the last flush.
  Future<void> markMessageCompleted({
    required String messageId,
    String? finalContent,
    Map<String, dynamic>? finalMetadata,
  }) async {
    final db = await database;
    try {
      final updates = <String, dynamic>{};

      if (finalMetadata != null) {
        finalMetadata['status'] = 'completed';
        finalMetadata['completed_at'] = DateTime.now().toIso8601String();
        updates['metadata'] = jsonEncode(finalMetadata);
      } else {
        // Read current metadata and update status
        final result = await db.query(
          'messages',
          where: 'id = ?',
          whereArgs: [messageId],
          limit: 1,
        );

        if (result.isNotEmpty) {
          final msg = result.first;
          final metadata = jsonDecode(msg['metadata'] as String? ?? '{}')
              as Map<String, dynamic>;
          metadata['status'] = 'completed';
          metadata['completed_at'] = DateTime.now().toIso8601String();
          updates['metadata'] = jsonEncode(metadata);
        }
      }

      if (finalContent != null) {
        updates['content'] = finalContent;
      }

      if (updates.isNotEmpty) {
        await db.update(
          'messages',
          updates,
          where: 'id = ?',
          whereArgs: [messageId],
        );

        LoggerService().debug(
          'Marked message as completed: $messageId',
          tag: 'LocalDatabaseService',
        );
      }
    } catch (e, st) {
      LoggerService().error(
        'Failed to mark message as completed',
        tag: 'LocalDatabaseService',
        error: e,
        stackTrace: st,
      );
      // Don't rethrow — message was already persisted
    }
  }

  /// Retrieve all partial or streaming messages for a channel.
  /// 
  /// Used for recovery UI on app restart to show incomplete messages
  /// that were interrupted mid-transmission.
  Future<List<Map<String, dynamic>>> getPartialMessages(String channelId) async {
    final db = await database;
    try {
      // SQLite JSON_EXTRACT for status field in metadata
      const jsonQuery = r'json_extract(metadata, "$.status")';
      final results = await db.query(
        'messages',
        where: 'channel_id = ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
        whereArgs: [channelId],
        orderBy: 'created_at DESC',
        limit: 50, // Reasonable limit for recovery
      );

      LoggerService().debug(
        'Retrieved ${results.length} partial messages for channel $channelId',
        tag: 'LocalDatabaseService',
      );

      return results;
    } catch (e, st) {
      LoggerService().error(
        'Failed to retrieve partial messages',
        tag: 'LocalDatabaseService',
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  /// Retrieve a specific partial message by ID.
  /// 
  /// Returns null if not found or if the message is not in 'partial' state.
  Future<Map<String, dynamic>?> getPartialMessage(String messageId) async {
    final db = await database;
    try {
      const jsonQuery = r'json_extract(metadata, "$.status")';
      final results = await db.query(
        'messages',
        where: 'id = ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
        whereArgs: [messageId],
        limit: 1,
      );

      return results.isNotEmpty ? results.first : null;
    } catch (e) {
      LoggerService().error(
        'Failed to retrieve partial message: $messageId',
        tag: 'LocalDatabaseService',
        error: e,
      );
      return null;
    }
  }

  /// Clean up old partial messages that were never completed.
  /// 
  /// Called periodically to prevent accumulation of stuck partial messages.
  /// Marks messages as 'abandoned' if they're older than [daysOld].
  Future<int> cleanupAbandonedPartialMessages({int daysOld = 30}) async {
    final db = await database;
    try {
      final cutoffDate =
          DateTime.now().subtract(Duration(days: daysOld)).toIso8601String();

      // Find abandoned partial messages
      const jsonQuery = r'json_extract(metadata, "$.status")';
      final results = await db.query(
        'messages',
        where: 'created_at < ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
        whereArgs: [cutoffDate],
      );

      if (results.isEmpty) {
        return 0;
      }

      // Mark them as abandoned
      for (final msg in results) {
        final messageId = msg['id'] as String;
        final metadata =
            jsonDecode(msg['metadata'] as String? ?? '{}') as Map<String, dynamic>;
        metadata['status'] = 'abandoned';
        metadata['abandoned_at'] = DateTime.now().toIso8601String();

        await db.update(
          'messages',
          {'metadata': jsonEncode(metadata)},
          where: 'id = ?',
          whereArgs: [messageId],
        );
      }

      LoggerService().info(
        'Cleaned up ${results.length} abandoned partial messages (older than $daysOld days)',
        tag: 'LocalDatabaseService',
      );

      return results.length;
    } catch (e, st) {
      LoggerService().error(
        'Failed to cleanup abandoned partial messages',
        tag: 'LocalDatabaseService',
        error: e,
        stackTrace: st,
      );
      return 0;
    }
  }
}

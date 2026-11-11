import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../local_database_service.dart';
import '../logger_service.dart';
import '../../storage/pouch_chat_log.dart';
import '../../storage/runtime_mirror_service.dart';
import '../../peer/hub_event_apply.dart' show liveTurnPlaceholderPrefix;

/// `messages.created_at` 的唯一写法：UTC、毫秒，和主机同步下来的行同一格式。
///
/// 这一列按字符串比较排序。混进不带时区的本地时间，会排到 UTC 行的后面。
String messageCreatedAt(DateTime time) => DateTime.fromMillisecondsSinceEpoch(
      time.millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String();

/// 把外部带进来的 `created_at` 改成 [messageCreatedAt] 的格式。不带时区的按本机时区算。
String normalizeMessageCreatedAt(String raw) {
  final parsed = DateTime.tryParse(raw);
  return parsed == null ? raw : messageCreatedAt(parsed);
}

/// 一次 [MessageDao.createMessages] 要写入的行。
class StoredMessageInsert {
  final String id;
  final String channelId;
  final String senderId;
  final String senderType;
  final String senderName;
  final String content;
  final String messageType;
  final Map<String, dynamic>? metadata;
  final String? replyToId;
  final DateTime createdAt;
  final int isRead;
  final ConflictAlgorithm conflictAlgorithm;

  const StoredMessageInsert({
    required this.id,
    required this.channelId,
    required this.senderId,
    required this.senderType,
    required this.senderName,
    required this.content,
    this.messageType = 'text',
    this.metadata,
    this.replyToId,
    required this.createdAt,
    this.isRead = 0,
    this.conflictAlgorithm = ConflictAlgorithm.abort,
  });
}

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
    DateTime? createdAt,
    int isRead = 0,
    ConflictAlgorithm conflictAlgorithm = ConflictAlgorithm.abort,
  }) async {
    final db = await database;
    final atTime = createdAt ?? DateTime.now();
    final at = messageCreatedAt(atTime);
    var effectiveIsRead = isRead;
    if (effectiveIsRead == 0 && createdAt != null) {
      final watermarkMs = await getChannelReadWatermarkMs(
        channelId,
        agentId: senderId,
      );
      if (watermarkMs > 0 && atTime.millisecondsSinceEpoch <= watermarkMs) {
        effectiveIsRead = 1;
      }
    }
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
        'created_at': at,
        'is_read': effectiveIsRead,
      },
      conflictAlgorithm: conflictAlgorithm,
    );
    // SQLite 仍是界面读取来源；储物袋日志是随袋子迁移的副本（fail-open）。
    RuntimeMirrorService.instance.onMessageCreated(channelId);
    notifyChannelActivity(channelId);
    _notePouchChat(PouchChatRecord(
      id: id,
      channelId: channelId,
      senderId: senderId,
      senderType: senderType,
      senderName: senderName,
      content: content,
      messageType: messageType,
      createdAt: at,
      metadata: metadata,
      replyToId: replyToId,
      isRead: effectiveIsRead,
    ));
  }

  /// 批量写入。历史同步用它替代逐条 [createMessage]，避免几百次往返。
  /// 每个频道只触发一次 runtime 镜像。
  Future<void> createMessages(List<StoredMessageInsert> rows) async {
    if (rows.isEmpty) return;
    final db = await database;
    final watermarks = <String, int>{};
    for (final row in rows) {
      if (!watermarks.containsKey(row.channelId)) {
        watermarks[row.channelId] = await getChannelReadWatermarkMs(
          row.channelId,
          agentId: row.senderId,
        );
      }
    }
    final batch = db.batch();
    for (final row in rows) {
      final wm = watermarks[row.channelId] ?? 0;
      final effectiveIsRead = (row.isRead != 0 ||
              (wm > 0 && row.createdAt.millisecondsSinceEpoch <= wm))
          ? 1
          : 0;
      batch.insert(
        'messages',
        {
          'id': row.id,
          'channel_id': row.channelId,
          'sender_id': row.senderId,
          'sender_type': row.senderType,
          'sender_name': row.senderName,
          'content': row.content,
          'message_type': row.messageType,
          'metadata': row.metadata != null ? jsonEncode(row.metadata) : null,
          'reply_to_id': row.replyToId,
          'created_at': messageCreatedAt(row.createdAt),
          'is_read': effectiveIsRead,
        },
        conflictAlgorithm: row.conflictAlgorithm,
      );
    }
    await batch.commit(noResult: true);
    final channels = <String>{for (final row in rows) row.channelId};
    for (final channelId in channels) {
      RuntimeMirrorService.instance.onMessageCreated(channelId);
      notifyChannelActivity(channelId);
    }
    _notePouchChatAll([
      for (final row in rows)
        PouchChatRecord(
          id: row.id,
          channelId: row.channelId,
          senderId: row.senderId,
          senderType: row.senderType,
          senderName: row.senderName,
          content: row.content,
          messageType: row.messageType,
          createdAt: messageCreatedAt(row.createdAt),
          metadata: row.metadata,
          replyToId: row.replyToId,
          isRead: row.isRead,
        ),
    ]);
  }

  /// 按 id 批量删除。SQLite 变量数有上限，所以分块。
  Future<void> deleteMessagesByIds(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    const chunkSize = 400;
    final located = <({String id, String channelId})>[];
    if (PouchChatLog.bound != null) {
      for (var i = 0; i < ids.length; i += chunkSize) {
        final end = i + chunkSize < ids.length ? i + chunkSize : ids.length;
        final chunk = ids.sublist(i, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await db.query(
          'messages',
          columns: ['id', 'channel_id'],
          where: 'id IN ($placeholders)',
          whereArgs: chunk,
        );
        for (final row in rows) {
          located.add((
            id: row['id'] as String? ?? '',
            channelId: row['channel_id'] as String? ?? '',
          ));
        }
      }
    }
    for (var i = 0; i < ids.length; i += chunkSize) {
      final end = i + chunkSize < ids.length ? i + chunkSize : ids.length;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      await db.delete(
        'messages',
        where: 'id IN ($placeholders)',
        whereArgs: chunk,
      );
    }
    final log = PouchChatLog.bound;
    if (log == null) return;
    for (final row in located) {
      if (row.id.isEmpty || row.channelId.isEmpty) continue;
      unawaited(
          log.tombstone(channelId: row.channelId, messageId: row.id).catchError(
        (Object e) {
          LoggerService().warning(
            'pouch chat tombstone failed: $e',
            tag: 'PouchChat',
          );
        },
      ));
    }
  }

  /// 获取 Channel 的消息
  ///
  /// `rowid` 是排序的次级键：`created_at` 并不保证唯一——peer 历史同步回灌的
  /// 时间戳来自引擎 transcript，精度可能只到分钟，同一分钟的两个回合会拿到
  /// 相同的戳。只按 created_at 排序时它们的先后是任意的，回复会被排到别的
  /// 提问下面。插入顺序即到达顺序，可以稳定地打破这种平局。
  Future<List<Map<String, dynamic>>> getChannelMessages(String channelId,
      {int limit = 100, int offset = 0}) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
      orderBy: 'created_at DESC, rowid DESC',
      limit: limit,
      offset: offset,
    );
  }

  /// 加载严格早于 [beforeCreatedAt] 的更早消息（`created_at DESC`，调用方再排序）。
  Future<List<Map<String, dynamic>>> getChannelMessagesBefore(
    String channelId,
    String beforeCreatedAt, {
    int limit = 50,
  }) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'channel_id = ? AND created_at < ?',
      whereArgs: [channelId, beforeCreatedAt],
      orderBy: 'created_at DESC, rowid DESC',
      limit: limit,
    );
  }

  /// 频道全部消息条数（含非 text），用于分页 hasMore 判定。
  Future<int> countChannelMessages(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM messages WHERE channel_id = ?',
      [channelId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 按 metadata JSON 子串检索频道消息（不受「最近 N 条」窗口限制）。
  ///
  /// 用于启动时的审批对账：直接定位某条 plan_approval / action_confirmation
  /// 卡片，避免旧卡片落在消息页窗口外导致脏行永远无法自愈。
  /// [needle] 必须是 jsonEncode 后的确定子串，如 `"_workflowId":"<uuid>"`。
  Future<List<Map<String, dynamic>>> getChannelMessagesByMetadataMatch(
    String channelId,
    String needle, {
    int limit = 20,
  }) async {
    final db = await database;
    return await db.query(
      'messages',
      where: 'channel_id = ? AND metadata LIKE ?',
      whereArgs: [channelId, '%$needle%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// 不限频道，按 metadata 子串找消息。
  ///
  /// 作废帧只带交互 id，当时的聊天页可能已经不在了，只能全库找这张卡。
  /// [needle] 应是 jsonEncode 后的确定子串（交互 id 本身即可）。
  Future<List<Map<String, dynamic>>> findMessagesByMetadataMatch(
    String needle, {
    int limit = 20,
    bool escapeWildcards = false,
  }) async {
    if (needle.isEmpty) return const [];
    final db = await database;
    // LIKE 的 % / _ 是通配符：approval_id 常含 `_`，不转义会把别的卡片行
    // 也捞进来，归属出现假歧义。
    final pattern = escapeWildcards
        ? needle
            .replaceAll('\\', '\\\\')
            .replaceAll('%', '\\%')
            .replaceAll('_', '\\_')
        : needle;
    return await db.query(
      'messages',
      where: escapeWildcards
          ? r"metadata LIKE ? ESCAPE '\'"
          : 'metadata LIKE ?',
      whereArgs: ['%$pattern%'],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// 某个频道里本机流式占位行的 id。
  ///
  /// 占位 id 是确定性的 `hub-live-<turnId>`，但 turnId 只活在内存里的
  /// 回合索引中。App 重启后最终 `message.created` 被重放时内存里已经没有
  /// 这个回合了，只能按前缀在库里找出来删掉，否则同一回合会留下
  /// 「收尾占位 + 最终消息」两条气泡。
  Future<List<String>> listLiveTurnPlaceholderIds(String channelId) async {
    if (channelId.isEmpty) return const [];
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: const ['id'],
      where: 'channel_id = ? AND id LIKE ?',
      whereArgs: [channelId, '$liveTurnPlaceholderPrefix%'],
    );
    return [
      for (final row in rows)
        if ((row['id'] as String? ?? '').isNotEmpty) row['id'] as String,
    ];
  }

  /// 全库一次取回所有本机流式占位行（A9-4 启动时重建 retain 集合用）。
  ///
  /// 按频道逐条扫会变成长历史重放里每条消息一次查询；这里只扫一次，之后靠
  /// 内存里的频道标记决定还要不要按频道查。
  Future<List<Map<String, dynamic>>> listLiveTurnPlaceholderRows() async {
    final db = await database;
    return await db.query(
      'messages',
      columns: const ['id', 'channel_id', 'metadata'],
      where: 'id LIKE ?',
      whereArgs: ['$liveTurnPlaceholderPrefix%'],
    );
  }

  /// 根据 ID 获取单条消息
  Future<Map<String, dynamic>?> getMessageById(String messageId) async {
    final db = await database;
    final results = await db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    return results.isEmpty ? null : results.first;
  }

  /// 标记消息为已读
  Future<void> markMessageAsRead(String messageId) async {
    final db = await database;
    final updated = await db.update(
      'messages',
      {'is_read': 1},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notePouchFromSqlite(messageId);
    if (updated > 0) {
      notifyChannelActivity();
    }
  }

  /// 删除消息
  Future<void> deleteMessage(String messageId) async {
    final db = await database;
    final deleted = await db.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );
    if (deleted > 0) {
      notifyChannelActivity();
    }
  }

  /// 统计 channel 中 created_at >= [createdAt] 的消息数量（含该时间点）。
  Future<int> countMessagesFromTimestamp(
      String channelId, String createdAt) async {
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

  /// 获取 Channel 中文本消息的总数
  Future<int> getChannelMessageCount(String channelId) async {
    final db = await database;
    final result = await db.rawQuery(
      "SELECT COUNT(*) as cnt FROM messages WHERE channel_id = ? AND message_type = 'text'",
      [channelId],
    );
    return (result.first['cnt'] as int?) ?? 0;
  }

  /// 按 id 取一个 channel 里的消息。历史切片同步用它，不再按位置对齐最近 2000 条。
  Future<List<Map<String, dynamic>>> getChannelMessagesByIds(
    String channelId,
    List<String> ids,
  ) async {
    if (ids.isEmpty) return const [];
    final db = await database;
    const chunkSize = 400;
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += chunkSize) {
      final end = i + chunkSize < ids.length ? i + chunkSize : ids.length;
      final chunk = ids.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'messages',
        where: 'channel_id = ? AND id IN ($placeholders)',
        whereArgs: [channelId, ...chunk],
      );
      out.addAll(rows);
    }
    return out;
  }

  Future<bool> channelHasPeerhistMessages(String channelId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: const ['id'],
      where: "channel_id = ? AND id GLOB 'peerhist_*'",
      whereArgs: [channelId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<List<({String id, String createdAt})>> listPeerhistStamps(
    String channelId,
  ) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: const ['id', 'created_at'],
      where: "channel_id = ? AND id GLOB 'peerhist_*'",
      whereArgs: [channelId],
    );
    return [
      for (final row in rows)
        if (row['id'] is String && row['created_at'] is String)
          (id: row['id'] as String, createdAt: row['created_at'] as String),
    ];
  }

  /// 手机本地产生、还没被 `peerhist_*` 覆盖的行。增量同步只在这些行上做删除判断。
  Future<List<Map<String, dynamic>>> listNonPeerhistMessages(
    String channelId,
  ) async {
    final db = await database;
    return db.query(
      'messages',
      columns: const [
        'id',
        'sender_type',
        'content',
        'metadata',
        'reply_to_id',
        'is_read',
      ],
      where: "channel_id = ? AND id NOT GLOB 'peerhist_*'",
      whereArgs: [channelId],
    );
  }

  /// 把 [channelId] 里指向 [fromId] 的引用改指到 [toId]（消息重键时用）。
  ///
  /// 发消息当下用户行还是裸 id，助手回复行记的 `reply_to_id` 也是那个裸 id；
  /// 主机的 `message.created` 到了之后用户行改叫 `peerhist_<id>`。引用不跟着
  /// 搬就悬空，气泡上会渲染出「原消息不可用」。返回改了几行。
  ///
  /// 只看 `channel_id`（有索引）—— 引用不会跨频道。
  Future<int> rewriteReplyToIds(
    String channelId,
    String fromId,
    String toId,
  ) async {
    if (channelId.isEmpty || fromId.isEmpty || toId.isEmpty) return 0;
    if (fromId == toId) return 0;
    final db = await database;
    return db.update(
      'messages',
      {'reply_to_id': toId},
      where: 'channel_id = ? AND reply_to_id = ?',
      whereArgs: [channelId, fromId],
    );
  }

  /// 删除 Channel 的所有消息
  Future<void> deleteChannelMessages(String channelId) async {
    final db = await database;
    await db.delete(
      'messages',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    // 不清游标的话，下次增量同步只会拿到最后一条，清空的记录回不来。
    await db.delete(
      'peer_history_cursor',
      where: 'channel_id = ?',
      whereArgs: [channelId],
    );
    notifyChannelActivity(channelId);
    final log = PouchChatLog.bound;
    if (log != null) {
      unawaited(log.deleteChannel(channelId).catchError((Object e) {
        LoggerService().warning(
          'pouch chat channel delete failed: $e',
          tag: 'PouchChat',
        );
      }));
    }
  }

  /// 更新消息内容
  Future<void> updateMessage({
    required String messageId,
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    final db = await database;
    final updateData = <String, dynamic>{
      'content': content,
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
    _notePouchFromSqlite(messageId);
  }

  /// 批量改写正文（只改 content，metadata 不动）。
  ///
  /// 进会话 / 翻页时可能一整页都要把「展示口径」的正文回写进库（例如把
  /// thinking 折叠掉），逐条 [updateMessage] 是 N 次往返加 N 次回查。
  Future<void> updateMessageContents(Map<String, String> contentById) async {
    if (contentById.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in contentById.entries) {
      batch.update(
        'messages',
        {'content': entry.value},
        where: 'id = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
    final ids = contentById.keys.toList(growable: false);
    try {
      for (var start = 0; start < ids.length; start += 400) {
        final end = start + 400 > ids.length ? ids.length : start + 400;
        final chunk = ids.sublist(start, end);
        final rows = await db.query(
          'messages',
          where: 'id IN (${List.filled(chunk.length, '?').join(',')})',
          whereArgs: chunk,
        );
        for (final row in rows) {
          await PouchChatLog.bound?.upsert(PouchChatRecord.fromSqliteRow(row));
        }
      }
    } catch (e) {
      LoggerService().warning(
        'pouch chat mirror failed: $e',
        tag: 'PouchChat',
      );
    }
  }

  Future<void> updateMessageMetadata(
      String messageId, Map<String, dynamic> metadata) async {
    final db = await database;
    await db.update(
      'messages',
      {'metadata': jsonEncode(metadata)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notePouchFromSqlite(messageId);
  }

  /// 只改 [patch] 里的 key：读–改–写在同一次调用里完成。
  ///
  /// 后台任务（附件双写、事件合并）手里往往是一份旧的 metadata 快照；
  /// 整份回写会把别处刚写进去的字段（撤回、回应、`pouch_uri` 更新…）覆盖掉。
  Future<void> mergeMessageMetadata(
    String messageId,
    Map<String, dynamic> patch,
  ) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['metadata'],
      where: 'id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final raw = rows.first['metadata'] as String?;
    final current = <String, dynamic>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) current.addAll(decoded);
      } catch (_) {
        // 坏 JSON：原内容反正读不出来，至少把 patch 写进去。
      }
    }
    current.addAll(patch);
    await db.update(
      'messages',
      {'metadata': jsonEncode(current)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notePouchFromSqlite(messageId);
  }

  /// 把已有行的 `created_at` 拨到现在，让复用的审计气泡排到本回合末尾。
  Future<void> touchMessageCreatedAt(String messageId) async {
    final db = await database;
    await db.update(
      'messages',
      {'created_at': messageCreatedAt(DateTime.now())},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    _notePouchFromSqlite(messageId);
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
    final now = messageCreatedAt(DateTime.now());

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

    _notePouchFromSqlite(messageId);
    return messageId;
  }

  /// 查找某 channel 内某 sender 最近一条 `status: streaming` 的半成品行 id。
  ///
  /// 进程被杀后恢复 peer turn 时用于收养杀进程前 flush 落库的 partial 行：
  /// 恢复出的 ActiveTask 认领该 id 后，后续 flush 继续更新同一行，turn 完成
  /// 时 deletePartial 能把它删掉——否则 DB 里会残留一条半成品消息，与随后
  /// 落库的完整消息并存（界面上表现为两条回复）。metadata 的两种 LIKE 形态
  /// 与 peer_inflight_turn.dart 的 peerHistorySyncRowIsStreaming 对齐。
  Future<String?> findLatestStreamingPartialMessageId({
    required String channelId,
    required String senderId,
  }) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      columns: ['id'],
      where: "channel_id = ? AND sender_id = ? AND sender_type = 'agent' AND "
          '(metadata LIKE \'%"status":"streaming"%\' OR '
          'metadata LIKE \'%"status": "streaming"%\')',
      whereArgs: [channelId, senderId],
      orderBy: 'created_at DESC, rowid DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['id'] as String?;
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
      final metadata = jsonDecode(msg['metadata'] as String? ?? '{}')
          as Map<String, dynamic>;

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
  Future<List<Map<String, dynamic>>> getPartialMessages(
      String channelId) async {
    final db = await database;
    try {
      // SQLite JSON_EXTRACT for status field in metadata
      const jsonQuery = r'json_extract(metadata, "$.status")';
      final results = await db.query(
        'messages',
        where:
            'channel_id = ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
        whereArgs: [channelId],
        orderBy: 'created_at DESC, rowid DESC',
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
        where:
            'id = ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
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
      final cutoffDate = messageCreatedAt(
        DateTime.now().subtract(Duration(days: daysOld)),
      );

      // Find abandoned partial messages
      const jsonQuery = r'json_extract(metadata, "$.status")';
      final results = await db.query(
        'messages',
        where:
            'created_at < ? AND ($jsonQuery = "streaming" OR $jsonQuery = "partial")',
        whereArgs: [cutoffDate],
      );

      if (results.isEmpty) {
        return 0;
      }

      // Mark them as abandoned
      for (final msg in results) {
        final messageId = msg['id'] as String;
        final metadata = jsonDecode(msg['metadata'] as String? ?? '{}')
            as Map<String, dynamic>;
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

  void _notePouchFromSqlite(String messageId) {
    final log = PouchChatLog.bound;
    if (log == null) return;
    unawaited(() async {
      final db = await database;
      final rows = await db.query(
        'messages',
        where: 'id = ?',
        whereArgs: [messageId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await log.upsert(PouchChatRecord.fromSqliteRow(rows.first));
    }()
        .then((_) {}, onError: (Object e, StackTrace _) {
      LoggerService().warning(
        'pouch chat mirror failed: $e',
        tag: 'PouchChat',
      );
    }));
  }
}

void _notePouchChat(PouchChatRecord record) {
  final log = PouchChatLog.bound;
  if (log == null) return;
  unawaited(log.upsert(record).then((_) {}, onError: (Object e, StackTrace _) {
    LoggerService().warning('pouch chat mirror failed: $e', tag: 'PouchChat');
  }));
}

void _notePouchChatAll(List<PouchChatRecord> records) {
  final log = PouchChatLog.bound;
  if (log == null || records.isEmpty) return;
  unawaited(
      log.upsertAll(records).then((_) {}, onError: (Object e, StackTrace _) {
    LoggerService().warning('pouch chat mirror failed: $e', tag: 'PouchChat');
  }));
}

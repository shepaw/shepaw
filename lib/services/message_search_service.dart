import 'dart:convert';
import 'logger_service.dart';
import '../models/message.dart';
import 'local_database_service.dart';

/// 消息搜索服务 - 支持跨会话搜索
class MessageSearchService {
  final LocalDatabaseService _database;
  MessageSearchService(this._database);

  /// 搜索消息（跨所有会话）
  /// 返回包含 channelName 的搜索结果
  /// [channelId] 限定单个会话搜索
  /// [channelIds] 限定多个会话搜索（用于搜索某个 agent 的所有 session）
  Future<List<MessageSearchResult>> searchMessages({
    required String query,
    String? channelId,
    List<String>? channelIds,
    String? userId,
    int limit = 50,
  }) async {
    try {
      if (query.trim().isEmpty) {
        return [];
      }

      final db = await _database.database;

      String channelFilter = '';
      List<dynamic> args = ['%$query%'];

      if (channelId != null) {
        channelFilter = 'AND m.channel_id = ?';
        args.add(channelId);
      } else if (channelIds != null && channelIds.isNotEmpty) {
        final placeholders = channelIds.map((_) => '?').join(', ');
        channelFilter = 'AND m.channel_id IN ($placeholders)';
        args.addAll(channelIds);
      }

      args.add(limit);

      String sql = '''
        SELECT m.*, c.name AS channel_name
        FROM messages m
        LEFT JOIN channels c ON m.channel_id = c.id
        WHERE m.content LIKE ?
        $channelFilter
        ORDER BY m.created_at DESC
        LIMIT ?
      ''';

      final List<Map<String, dynamic>> maps = await db.rawQuery(sql, args);

      return maps.map((map) {
        // Parse metadata
        Map<String, dynamic>? metadata;
        if (map['metadata'] != null) {
          try {
            if (map['metadata'] is String) {
              metadata = Map<String, dynamic>.from(
                jsonDecode(map['metadata'] as String),
              );
            } else if (map['metadata'] is Map) {
              metadata = Map<String, dynamic>.from(map['metadata']);
            }
          } catch (e) {
            LoggerService().error('Error parsing metadata: $e', tag: 'Search');
          }
        }

        // Parse reply_to
        String? replyTo = map['reply_to_id'] as String?;

        // Parse created_at to milliseconds
        int timestampMs;
        try {
          timestampMs = DateTime.parse(map['created_at'] as String)
              .millisecondsSinceEpoch;
        } catch (_) {
          timestampMs = DateTime.now().millisecondsSinceEpoch;
        }

        final message = Message(
          id: map['id'] as String,
          from: MessageFrom(
            id: map['sender_id'] as String? ?? '',
            type: map['sender_type'] as String? ?? 'user',
            name: map['sender_name'] as String? ?? '',
          ),
          channelId: map['channel_id'] as String?,
          type: _parseMessageType(map['message_type'] as String? ?? 'text'),
          content: map['content'] as String? ?? '',
          timestampMs: timestampMs,
          replyTo: replyTo,
          metadata: metadata,
        );

        // 提取 channel_name，去掉 "Chat with " 前缀以简洁显示
        String channelName = map['channel_name'] as String? ?? '';
        if (channelName.startsWith('Chat with ')) {
          channelName = channelName.substring('Chat with '.length);
        }

        return MessageSearchResult(
          message: message,
          channelName: channelName,
        );
      }).toList();
    } catch (e) {
      LoggerService().error('Error searching messages: $e', tag: 'Search');
      return [];
    }
  }

  /// 按日期搜索消息
  Future<List<MessageSearchResult>> searchMessagesByDate({
    required DateTime startDate,
    required DateTime endDate,
    String? channelId,
  }) async {
    try {
      final db = await _database.database;

      String sql = '''
        SELECT m.*, c.name AS channel_name
        FROM messages m
        LEFT JOIN channels c ON m.channel_id = c.id
        WHERE m.created_at >= ? AND m.created_at <= ?
        ${channelId != null ? 'AND m.channel_id = ?' : ''}
        ORDER BY m.created_at DESC
      ''';

      List<dynamic> args = [
        startDate.toIso8601String(),
        endDate.toIso8601String(),
      ];
      if (channelId != null) {
        args.add(channelId);
      }

      final List<Map<String, dynamic>> maps = await db.rawQuery(sql, args);

      return maps.map((map) {
        Map<String, dynamic>? metadata;
        if (map['metadata'] != null) {
          try {
            if (map['metadata'] is String) {
              metadata = Map<String, dynamic>.from(
                jsonDecode(map['metadata'] as String),
              );
            } else if (map['metadata'] is Map) {
              metadata = Map<String, dynamic>.from(map['metadata']);
            }
          } catch (_) {}
        }

        int timestampMs;
        try {
          timestampMs = DateTime.parse(map['created_at'] as String)
              .millisecondsSinceEpoch;
        } catch (_) {
          timestampMs = DateTime.now().millisecondsSinceEpoch;
        }

        final message = Message(
          id: map['id'] as String,
          from: MessageFrom(
            id: map['sender_id'] as String? ?? '',
            type: map['sender_type'] as String? ?? 'user',
            name: map['sender_name'] as String? ?? '',
          ),
          channelId: map['channel_id'] as String?,
          type: _parseMessageType(map['message_type'] as String? ?? 'text'),
          content: map['content'] as String? ?? '',
          timestampMs: timestampMs,
          metadata: metadata,
        );

        String channelName = map['channel_name'] as String? ?? '';
        if (channelName.startsWith('Chat with ')) {
          channelName = channelName.substring('Chat with '.length);
        }

        return MessageSearchResult(
          message: message,
          channelName: channelName,
        );
      }).toList();
    } catch (e) {
      LoggerService().error('Error searching messages by date: $e', tag: 'Search');
      return [];
    }
  }

  /// 获取搜索建议
  Future<List<String>> getSearchSuggestions({
    required String query,
    String? channelId,
    int limit = 10,
  }) async {
    try {
      if (query.length < 2) return [];

      final db = await _database.database;

      String sql = '''
        SELECT DISTINCT
          SUBSTR(content, 1, 100) as snippet
        FROM messages
        WHERE content LIKE ?
        ${channelId != null ? 'AND channel_id = ?' : ''}
        LIMIT ?
      ''';

      List<dynamic> args = ['%$query%'];
      if (channelId != null) {
        args.add(channelId);
      }
      args.add(limit);

      final List<Map<String, dynamic>> maps = await db.rawQuery(sql, args);

      return maps.map((map) => map['snippet'] as String).toList();
    } catch (e) {
      LoggerService().error('Error getting search suggestions: $e', tag: 'Search');
      return [];
    }
  }

  /// 解析消息类型
  MessageType _parseMessageType(String type) {
    switch (type.toLowerCase()) {
      case 'image':
        return MessageType.image;
      case 'file':
        return MessageType.file;
      case 'audio':
        return MessageType.audio;
      case 'system':
        return MessageType.system;
      case 'text':
      default:
        return MessageType.text;
    }
  }
}

/// 搜索结果，包含消息和所属会话名称
class MessageSearchResult {
  final Message message;
  final String channelName;

  MessageSearchResult({
    required this.message,
    required this.channelName,
  });
}

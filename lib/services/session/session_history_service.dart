import 'dart:convert';
import '../../models/message.dart';
import '../../models/channel.dart';
import '../../models/tool_execution_result.dart';
import '../local_database_service.dart';
import '../tool_result_database_service.dart';
import '../inference_log_service.dart';
import '../logger_service.dart';
import 'package:uuid/uuid.dart';

/// Handles session (channel) lifecycle for 1:1 agent conversations.
class SessionService {
  final LocalDatabaseService _db;

  SessionService(this._db);

  /// Create a new session (channel) for user-agent conversation.
  Future<String> createNewSession({
    required String userId,
    required String userName,
    required String agentId,
    required String agentName,
  }) async {
    final ids = [userId, agentId]..sort();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final channelId = 'dm_${ids.join('_')}_$timestamp';

    final channel = Channel.withMemberIds(
      id: channelId,
      name: 'Chat with $agentName',
      type: 'dm',
      memberIds: [userId, agentId],
      isPrivate: true,
    );
    await _db.createChannel(channel, userId);
    return channelId;
  }

  /// Get the most recently active channel ID for a user-agent pair.
  Future<String?> getLatestActiveChannelId(String userId, String agentId) async {
    return await _db.getLatestActiveChannelForUserAndAgent(userId, agentId);
  }

  /// Get all sessions (channels) for a specific agent.
  ///
  /// 包含 `peer__` 入站会话——这些是本机作为 host 被配对设备访问时、为每个来源
  /// 设备维护的独立会话；它们应像旧 ACP 远程连接一样出现在本机被共享 agent 的
  /// 会话列表里，以保留独立的会话记录。
  Future<List<Channel>> getAgentSessions({required String agentId}) async {
    return await _db.getChannelsForAgent(agentId);
  }

  /// Get the deterministic channel ID for a user-agent pair.
  /// Note: this is a legacy channel ID; new sessions use timestamped IDs.
  String generateChannelId(String userId, String agentId) {
    final ids = [userId, agentId]..sort();
    return 'dm_${ids.join('_')}';
  }
}

/// Handles message history loading, rollback, and deletion for conversations.
class HistoryService {
  final LocalDatabaseService _db;
  final ToolResultDatabaseService _toolResultDb;

  HistoryService(this._db, this._toolResultDb);

  /// Load messages for a user-agent pair, using the most recently active channel.
  Future<List<Message>> loadMessageHistory({
    required String agentId,
    required String userId,
    int limit = 100,
  }) async {
    final activeChannelId = await _db.getLatestActiveChannelForUserAndAgent(userId, agentId);
    final channelId = activeChannelId ?? _generateChannelId(userId, agentId);
    return await loadChannelMessages(channelId, limit: limit);
  }

  /// Load messages from a channel.
  Future<List<Message>> loadChannelMessages(String channelId, {int limit = 100}) async {
    final messageMaps = await _db.getChannelMessages(channelId, limit: limit);

    return messageMaps.map((map) {
      Map<String, dynamic>? metadata;
      if (map['metadata'] != null) {
        try {
          metadata = Map<String, dynamic>.from(jsonDecode(map['metadata'] as String));
        } catch (_) {}
      }

      return Message(
        id: map['id'] as String,
        from: MessageFrom(
          id: map['sender_id'] as String,
          type: map['sender_type'] as String,
          name: map['sender_name'] as String,
        ),
        channelId: channelId,
        type: _parseMessageType(map['message_type'] as String),
        content: map['content'] as String,
        timestampMs: DateTime.parse(map['created_at'] as String).millisecondsSinceEpoch,
        replyTo: map['reply_to_id'] as String?,
        metadata: metadata,
      );
    }).toList()
      ..sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
  }

  /// Get a single message by ID.
  Future<Message?> getMessageById(String messageId) async {
    final map = await _db.getMessageById(messageId);
    if (map == null) return null;

    Map<String, dynamic>? metadata;
    if (map['metadata'] != null) {
      try {
        metadata = Map<String, dynamic>.from(jsonDecode(map['metadata'] as String));
      } catch (_) {}
    }

    return Message(
      id: map['id'] as String,
      from: MessageFrom(
        id: map['sender_id'] as String,
        type: map['sender_type'] as String,
        name: map['sender_name'] as String,
      ),
      channelId: map['channel_id'] as String?,
      type: _parseMessageType(map['message_type'] as String),
      content: map['content'] as String,
      timestampMs: DateTime.parse(map['created_at'] as String).millisecondsSinceEpoch,
      replyTo: map['reply_to_id'] as String?,
      metadata: metadata,
    );
  }

  /// Delete chat history for an agent.
  /// Deletes the most recently active session, not just the deterministic channel.
  Future<void> deleteChatHistory({
    required String agentId,
    required String userId,
  }) async {
    final activeChannelId = await _db.getLatestActiveChannelForUserAndAgent(userId, agentId);
    final channelId = activeChannelId ?? _generateChannelId(userId, agentId);
    await _db.deleteChannel(channelId);
    await _toolResultDb.deleteByChannel(channelId);
    InferenceLogService.instance.removeByChannel(channelId);
  }

  /// Delete a single message.
  Future<void> deleteMessage(String messageId) async {
    try {
      await _db.deleteMessage(messageId);
      await _toolResultDb.deleteByMessage(messageId);
    } catch (e) {
      LoggerService().error('Error deleting message', tag: 'HistoryService', error: e);
      rethrow;
    }
  }

  /// Load and truncate history to fit within a character budget.
  Future<List<Message>> loadAndTruncateHistory(
    String channelId, {
    int maxChars = 60000,
    int limit = 100,
    String? excludeMessageId,
  }) async {
    final allMessages = await loadChannelMessages(channelId, limit: limit);
    var history = allMessages
        .where((m) => m.type != MessageType.system && m.type != MessageType.permissionAudit)
        .toList();
    if (excludeMessageId != null) {
      history.removeWhere((m) => m.id == excludeMessageId);
    }
    int totalChars = history.fold(0, (sum, m) => sum + m.content.length);
    while (totalChars > maxChars && history.isNotEmpty) {
      totalChars -= history.first.content.length;
      history.removeAt(0);
    }
    return history;
  }

  // ---------------------------------------------------------------------------
  // 工具调用历史重建
  // ---------------------------------------------------------------------------

  /// 构建用于发送给 LLM 的完整消息数组（OpenAI 格式），包含工具调用摘要。
  ///
  /// 策略（与 Claude Code 一致）：
  ///   - assistant 消息若含工具调用，在 tool_calls 数组中完整保留 tool_call_id /
  ///     name / arguments（模型需要看到自己当时的决策）
  ///   - role:tool 响应只放**摘要**（summary），避免大量原始输出撑爆上下文
  ///   - 模型如需完整结果，可调用 get_tool_result(tool_call_id) 工具主动拉取
  ///
  /// [excludeMessageId] 通常为当前正在生成中的 assistant 消息 ID，避免重复。
  Future<List<Map<String, dynamic>>> buildOpenAIMessages(
    String channelId, {
    int limit = 100,
    int maxChars = 60000,
    String? excludeMessageId,
  }) async {
    final messages = await loadAndTruncateHistory(
      channelId,
      limit: limit,
      maxChars: maxChars,
      excludeMessageId: excludeMessageId,
    );
    if (messages.isEmpty) return [];

    final messageIds = messages.map((m) => m.id).toList();
    final toolMap = await _toolResultDb.getToolExecutionsByMessageIds(messageIds);

    final result = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final execs = toolMap[msg.id] ?? [];

      if (msg.from.isAgent) {
        // ── assistant 消息 ──────────────────────────────────────────────────
        if (execs.isEmpty) {
          // 纯文本回复
          result.add({'role': 'assistant', 'content': msg.content});
        } else {
          // 包含工具调用：保留完整 tool_calls，文本内容可能为空
          final toolCallsJson = execs.map((e) {
            Map<String, dynamic>? args;
            if (e['arguments'] != null) {
              try {
                args = Map<String, dynamic>.from(
                  jsonDecode(e['arguments'] as String),
                );
              } catch (_) {
                args = {'raw': e['arguments']};
              }
            }
            return {
              'id': e['tool_call_id'],
              'type': 'function',
              'function': {
                'name': e['tool_name'],
                'arguments': args != null ? jsonEncode(args) : '{}',
              },
            };
          }).toList();

          result.add({
            'role': 'assistant',
            'content': msg.content.isEmpty ? null : msg.content,
            'tool_calls': toolCallsJson,
          });

          // ── 紧跟 tool 结果消息（每个 tool_call 对应一条）────────────────
          // OpenAI tool message content 只支持字符串，统一用 summary
          for (final e in execs) {
            final summary = e['summary'] as String? ??
                '[${e['tool_name']} result — call get_tool_result("${e['tool_call_id']}") for details]';
            result.add({
              'role': 'tool',
              'tool_call_id': e['tool_call_id'],
              'content': summary,
            });
          }
        }
      } else {
        // ── user 消息 ────────────────────────────────────────────────────────
        result.add({'role': 'user', 'content': msg.content});
      }
    }
    return result;
  }

  /// 构建用于发送给 LLM 的完整消息数组（Claude / Anthropic 格式），包含工具调用摘要。
  ///
  /// Claude 的 tool_use block 放在 assistant content 数组里，
  /// tool_result block 放在后续 user 消息的 content 数组里。
  ///
  /// 对于 content_blocks 类型的结果，tool_result 的 content 字段会还原为
  /// List<block>（包含图片等多模态内容）；其他类型使用摘要字符串。
  Future<List<Map<String, dynamic>>> buildClaudeMessages(
    String channelId, {
    int limit = 100,
    int maxChars = 60000,
    String? excludeMessageId,
  }) async {
    final messages = await loadAndTruncateHistory(
      channelId,
      limit: limit,
      maxChars: maxChars,
      excludeMessageId: excludeMessageId,
    );
    if (messages.isEmpty) return [];

    final messageIds = messages.map((m) => m.id).toList();
    final toolMap = await _toolResultDb.getToolExecutionsByMessageIds(messageIds);

    final result = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final execs = toolMap[msg.id] ?? [];

      if (msg.from.isAgent) {
        // ── assistant 消息 ──────────────────────────────────────────────────
        if (execs.isEmpty) {
          result.add({'role': 'assistant', 'content': msg.content});
        } else {
          // content 数组：先文本，再 tool_use block
          final contentParts = <Map<String, dynamic>>[];
          if (msg.content.isNotEmpty) {
            contentParts.add({'type': 'text', 'text': msg.content});
          }
          for (final e in execs) {
            Map<String, dynamic> inputArgs = {};
            if (e['arguments'] != null) {
              try {
                inputArgs = Map<String, dynamic>.from(
                  jsonDecode(e['arguments'] as String),
                );
              } catch (_) {
                inputArgs = {'raw': e['arguments']};
              }
            }
            contentParts.add({
              'type': 'tool_use',
              'id': e['tool_call_id'],
              'name': e['tool_name'],
              'input': inputArgs,
            });
          }
          result.add({'role': 'assistant', 'content': contentParts});

          // ── 紧跟 user 消息，包含所有 tool_result block ───────────────────
          // content_blocks 类型：还原完整多模态数组（含图片）
          // 其他类型：使用摘要字符串，节省上下文
          final toolResultBlocks = <Map<String, dynamic>>[];
          for (final e in execs) {
            final resultType = e['result_type'] as String? ?? 'text';
            final fullResult = e['full_result'] as String?;
            final summary = e['summary'] as String? ??
                '[${e['tool_name']} result — call get_tool_result("${e['tool_call_id']}") for details]';

            dynamic content;
            if (resultType == 'content_blocks' && fullResult != null) {
              // 还原完整 content blocks 数组，模型能看到原始图片等内容
              try {
                content = ToolExecutionResult.fromDb(
                  resultType: resultType,
                  serialized: fullResult,
                  summary: summary,
                ).toClaudeContent();
              } catch (_) {
                content = summary;
              }
            } else {
              // text / binary_ref：仅放摘要，完整内容按需通过 get_tool_result 获取
              content = summary;
            }

            toolResultBlocks.add({
              'type': 'tool_result',
              'tool_use_id': e['tool_call_id'],
              'content': content,
            });
          }
          result.add({'role': 'user', 'content': toolResultBlocks});
        }
      } else {
        // ── user 消息 ────────────────────────────────────────────────────────
        result.add({'role': 'user', 'content': msg.content});
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 工具执行记录写入（供 local_llm_handler 调用）
  // ---------------------------------------------------------------------------

  static final _uuid = Uuid();

  /// 在工具执行完成后，持久化 tool_use + tool_result 到 tool_executions 表。
  ///
  /// [messageId]   对应 assistant 消息的 ID（tool_use 所在消息）
  /// [channelId]   所属 channel
  /// [toolCallId]  LLM 生成的唯一工具调用 ID
  /// [toolName]    工具名称
  /// [arguments]   工具输入参数
  /// [result]      用 [ToolExecutionResult] 封装的工具执行结果
  Future<void> saveToolExecution({
    required String messageId,
    required String channelId,
    required String toolCallId,
    required String toolName,
    required Map<String, dynamic> arguments,
    required ToolExecutionResult result,
  }) async {
    // 先创建骨架（幂等：若已存在则忽略）
    await _toolResultDb.createToolExecution(
      id: _uuid.v4(),
      messageId: messageId,
      channelId: channelId,
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: arguments,
    );
    // 再回填结果（含类型）
    await _toolResultDb.updateToolExecutionResult(
      toolCallId: toolCallId,
      resultType: result.typeString,
      summary: result.summary,
      fullResult: result.serialized,
    );
  }

  /// 查询单条工具调用的完整结果，还原为 [ToolExecutionResult]。
  ///
  /// 供 get_tool_result 工具调用时使用，返回 null 表示记录不存在。
  Future<ToolExecutionResult?> getToolExecutionResult(String toolCallId) async {
    final row = await _toolResultDb.getToolExecutionByCallId(toolCallId);
    if (row == null) return null;
    final resultType = row['result_type'] as String? ?? 'text';
    final fullResult = row['full_result'] as String?;
    final summary = row['summary'] as String? ?? '';
    if (fullResult == null) return null;
    return ToolExecutionResult.fromDb(
      resultType: resultType,
      serialized: fullResult,
      summary: summary,
    );
  }

  String _generateChannelId(String userId, String agentId) {
    final ids = [userId, agentId]..sort();
    return 'dm_${ids.join('_')}';
  }

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
      case 'permission_audit':
        return MessageType.permissionAudit;
      default:
        return MessageType.text;
    }
  }
}

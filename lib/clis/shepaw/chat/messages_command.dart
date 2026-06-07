import 'dart:convert';

import '../../cli_base.dart';
import '../../../models/message.dart';
import '../../../services/local_database_service.dart';
import '../../../services/messaging/local_llm_handler.dart';

/// 查询频道消息
/// 支持两种定位方式：
///   --channel <id>        直接指定频道
///   --agent  <agent_id>   自动找当前 Agent ↔ 目标 agent 最近的 DM 频道
class ChatMessagesCommand extends CliCommand {
  final String agentId;

  ChatMessagesCommand({required this.agentId});

  final _db = LocalDatabaseService();

  @override
  String get name => 'messages';

  @override
  String get description =>
      'Query messages, --channel <id> or --agent <agent_id>, optional --limit N --offset N';

  @override
  String get usage =>
      'shepaw chat messages --channel <id> or --agent <agent_id> [--limit 20] [--offset 0]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'channel': {
        'description': 'Channel ID to query messages from',
        'required': 'one of channel or agent required',
        'type': 'string',
      },
      'agent': {
        'description': 'Agent ID — auto-finds the most recent DM channel between the current agent and this agent',
        'required': 'one of channel or agent required',
        'type': 'string',
      },
      'limit': {
        'description': 'Maximum number of messages to return',
        'required': false,
        'type': 'integer',
        'default': '20',
      },
      'offset': {
        'description': 'Message offset for pagination',
        'required': false,
        'type': 'integer',
        'default': '0',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    String? channelId = flags['channel'];

    if (channelId == null || channelId.isEmpty) {
      final targetAgentId = flags['agent'];
      if (targetAgentId != null && targetAgentId.isNotEmpty) {
        // 使用注入的 agentId（执行命令的 agent）查找与目标 agent 的 DM 频道
        channelId = await _db.getLatestActiveChannelForUserAndAgent(
            agentId, targetAgentId);
        if (channelId == null || channelId.isEmpty) {
          return {
            'error':
                'No channel found for agent $targetAgentId. Start a conversation in ShePaw first or use --channel directly.'
          };
        }
      } else {
        return {
          'error':
              'Must provide --channel <channel_id> or --agent <agent_id>.\n'
                  'Usage:\n'
                  '  shepaw chat messages --channel <id> [--limit 20] [--offset 0]\n'
                  '  shepaw chat messages --agent <agent_id> [--limit 20] [--offset 0]'
        };
      }
    }

    final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final offset = int.tryParse(flags['offset'] ?? '0') ?? 0;

    final msgs =
        await _db.getChannelMessages(channelId, limit: limit, offset: offset);

    final list = msgs.map((m) {
      final content = (m['content'] as String? ?? '');
      final snippet =
          content.length > 200 ? '${content.substring(0, 200)}…' : content;
      final messageType = m['message_type'] as String? ?? 'text';
      final hasAttachment = messageType == 'image' ||
          messageType == 'file' ||
          messageType == 'audio';

      final entry = <String, dynamic>{
        'id': m['id'],
        'sender': m['sender_name'] ?? m['sender_id'],
        'sender_id': m['sender_id'],
        'role': m['sender_type'],
        'message_type': messageType,
        'has_attachment': hasAttachment,
        'content': snippet,
        'created_at': m['created_at'],
      };

      if (hasAttachment) {
        Map<String, dynamic>? metadata;
        if (m['metadata'] != null) {
          try {
            metadata = Map<String, dynamic>.from(
              jsonDecode(m['metadata'] as String),
            );
          } catch (_) {}
        }
        entry['attachment_info'] = LocalLLMHelpers.buildAttachmentInfo(
          Message(
            id: m['id'] as String,
            from: MessageFrom(
              id: m['sender_id'] as String,
              type: m['sender_type'] as String,
              name: m['sender_name'] as String,
            ),
            channelId: m['channel_id'] as String?,
            type: _parseMessageType(messageType),
            content: content,
            timestampMs: DateTime.parse(m['created_at'] as String)
                .millisecondsSinceEpoch,
            metadata: metadata,
          ),
        );
      }

      return entry;
    }).toList();

    return {
      'channel_id': channelId,
      'limit': limit,
      'offset': offset,
      'count': list.length,
      'messages': list,
      'hint':
          'For full message content or image analysis: shepaw chat message get --id <message_id> [--analyze "..."]',
    };
  }

  MessageType _parseMessageType(String value) {
    switch (value) {
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

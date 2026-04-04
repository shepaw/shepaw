import '../../cli_base.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';

/// 查询频道消息
/// 支持两种定位方式：
///   --channel <id>        直接指定频道
///   --agent  <agent_id>   自动找 She ↔ agent 最近的 DM 频道
class ChatMessagesCommand extends CliCommand {
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
        'description': 'Agent ID — auto-finds the most recent DM channel with this agent',
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
      final agentId = flags['agent'];
      if (agentId != null && agentId.isNotEmpty) {
        channelId = await _db.getLatestActiveChannelForUserAndAgent(
            SheService.sheId, agentId);
        if (channelId == null || channelId.isEmpty) {
          return {
            'error':
                'No channel found for agent $agentId. Start a conversation in ShePaw first or use --channel directly.'
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
      return {
        'id': m['id'],
        'sender': m['sender_name'] ?? m['sender_id'],
        'sender_id': m['sender_id'],
        'role': m['sender_type'],
        'content': snippet,
        'created_at': m['created_at'],
      };
    }).toList();

    return {
      'channel_id': channelId,
      'limit': limit,
      'offset': offset,
      'count': list.length,
      'messages': list,
    };
  }
}

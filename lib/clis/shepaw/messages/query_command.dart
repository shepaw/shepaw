import '../../cli_base.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';

/// 查询频道消息
/// 支持两种定位方式：
///   --channel <id>        直接指定频道
///   --agent  <agent_id>   自动找 She ↔ agent 最近的 DM 频道
class QueryCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'query';

  @override
  String get description => 'Query messages, --channel <id> or --agent <agent_id>, optional --limit N --offset N';

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
            'error': 'No channel found for agent $agentId. Start a conversation in ShePaw first or use --channel directly.'
          };
        }
      } else {
        return {
          'error': 'Must provide --channel <channel_id> or --agent <agent_id>.\nUsage:\n  shepaw messages query --channel <id> [--limit 20] [--offset 0]\n  shepaw messages query --agent <agent_id> [--limit 20] [--offset 0]'
        };
      }
    }

    final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final offset = int.tryParse(flags['offset'] ?? '0') ?? 0;

    final msgs = await _db.getChannelMessages(channelId, limit: limit, offset: offset);

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

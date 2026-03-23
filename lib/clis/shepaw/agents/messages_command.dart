import '../../cli_base.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';

/// 查询 Agent 频道中的消息
class MessagesCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'messages';

  @override
  String get description =>
      'Query agent channel messages, --id <agent_id> [--channel <channel_id>] [--limit 20] [--offset 0]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents messages --id <agent_id> [--channel <channel_id>] [--limit 20] [--offset 0]'
      };
    }

    // Resolve channel: explicit flag > most recent She↔agent DM > any channel the agent is in
    String? channelId = flags['channel'];
    if (channelId == null || channelId.isEmpty) {
      channelId =
          await _db.getLatestActiveChannelForUserAndAgent(SheService.sheId, id);
      if (channelId == null || channelId.isEmpty) {
        final agentChans = await _db.getChannelsForAgent(id);
        if (agentChans.isNotEmpty) channelId = agentChans.first.id;
      }
    }

    if (channelId == null || channelId.isEmpty) {
      return {
        'error': 'No channel found for agent $id. Start a conversation first or use --channel to specify one.'
      };
    }

    final msgsLimit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final msgsOffset = int.tryParse(flags['offset'] ?? '0') ?? 0;
    final agentMsgs = await _db.getChannelMessages(
      channelId,
      limit: msgsLimit,
      offset: msgsOffset,
    );

    final agentMsgList = agentMsgs.map((m) {
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
      'agent_id': id,
      'channel_id': channelId,
      'limit': msgsLimit,
      'offset': msgsOffset,
      'count': agentMsgList.length,
      'messages': agentMsgList,
    };
  }
}

import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 列出 Agent 的频道
class ChannelsCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'channels';

  @override
  String get description => 'List agent conversation channels, --id <agent_id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {'error': 'Missing --id. Usage: shepaw agents channels --id <agent_id>'};
    }
    final agentChannels = await _db.getChannelsForAgent(id);
    final channelList = agentChannels
        .map((c) => {
              'id': c.id,
              'name': c.name,
              'type': c.type,
              'description': c.description,
              'last_message': c.lastMessage,
              'last_message_at': c.lastMessageTime?.toIso8601String(),
            })
        .toList();
    return {'agent_id': id, 'channels': channelList, 'count': channelList.length};
  }
}

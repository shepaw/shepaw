import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 以 She 身份向 Agent 发送消息
class ChatCommand extends CliCommand {
  final _db = LocalDatabaseService();

  /// Injected via ShepawCLI.instance.chatSender
  IPawChatSender? chatSender;

  @override
  String get name => 'chat';

  @override
  String get description =>
      'Send a message to agent as She, --id <agent_id> --message <text> [--channel <channel_id>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    final message = flags['message'];

    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents chat --id <agent_id> --message <text> [--channel <channel_id>]'
      };
    }
    if (message == null || message.isEmpty) {
      return {
        'error':
            'Missing --message. Usage: shepaw agents chat --id <agent_id> --message <text>'
      };
    }

    final targetAgent = await _db.getRemoteAgentById(id);
    if (targetAgent == null) {
      return {'error': 'Agent not found: $id'};
    }

    // Determine channel: use explicit flag, or find the most recently active channel for this agent
    String? channelId =
        flags['channel']?.isNotEmpty == true ? flags['channel'] : null;
    if (channelId == null) {
      final agentChans = await _db.getChannelsForAgent(id);
      if (agentChans.isNotEmpty) channelId = agentChans.first.id;
    }

    if (channelId == null || channelId.isEmpty) {
      return {
        'error':
            'No channel found for ${targetAgent.name}. Start a conversation in ShePaw first or specify --channel.'
      };
    }

    final sender = chatSender;
    if (sender == null) {
      return {'error': 'chatSender not initialized, cannot send message'};
    }

    await sender.sendAsSheTo(
      targetAgent: targetAgent,
      channelId: channelId,
      message: message,
    );

    return {
      'ok': true,
      'sent_to': targetAgent.name,
      'channel_id': channelId,
      'message_preview':
          message.length > 80 ? '${message.substring(0, 80)}…' : message,
    };
  }
}

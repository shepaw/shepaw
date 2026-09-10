import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../chat/chat_agent_scope.dart';

class EventsAckCommand extends CliCommand {
  @override
  String get name => 'ack';

  @override
  String get description => 'Acknowledge consumed inbox events';

  @override
  String get usage => 'shepaw events ack --id <event_id> | --correlation <cid>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final eventId = flags['id']?.trim();
    final correlation = flags['correlation']?.trim();
    if ((eventId == null || eventId.isEmpty) &&
        (correlation == null || correlation.isEmpty)) {
      return {'error': 'Provide --id or --correlation'};
    }

    final count = EventBus.instance.ackInbox(
      ChatAgentScope.agentId,
      eventId: eventId?.isEmpty == true ? null : eventId,
      correlationId: correlation?.isEmpty == true ? null : correlation,
    );

    return {'success': true, 'acked_count': count};
  }
}

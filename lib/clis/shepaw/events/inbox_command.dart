import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../chat/chat_agent_scope.dart';

class EventsInboxCommand extends CliCommand {
  @override
  String get name => 'inbox';

  @override
  String get description => 'List agent inbox events (poll)';

  @override
  String get usage =>
      'shepaw events inbox [--cursor N] [--limit 20] [--unread] [--correlation id] [--pattern type]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final agentId = ChatAgentScope.agentId;
    final cursor = int.tryParse(flags['cursor'] ?? '0') ?? 0;
    final limit = int.tryParse(flags['limit'] ?? '20') ?? 20;
    final unread = flags.containsKey('unread');
    final correlation = flags['correlation']?.trim();
    final pattern = flags['pattern']?.trim() ?? flags['type']?.trim();

    final entries = EventBus.instance.inboxFor(
      agentId,
      cursor: cursor,
      limit: limit.clamp(1, 100),
      unreadOnly: unread,
      correlationId: correlation?.isEmpty == true ? null : correlation,
      typePattern: pattern?.isEmpty == true ? null : pattern,
    );

    return {
      'agent_id': agentId,
      'cursor': cursor,
      'count': entries.length,
      'events': entries.map((e) => e.toJson()).toList(),
    };
  }
}

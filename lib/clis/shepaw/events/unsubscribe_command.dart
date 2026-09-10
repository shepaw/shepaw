import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../../../services/local_database_service.dart';
import '../chat/chat_agent_scope.dart';

class EventsUnsubscribeCommand extends CliCommand {
  @override
  String get name => 'unsubscribe';

  @override
  String get description => 'Remove an event subscription';

  @override
  String get usage => 'shepaw events unsubscribe --subscription <id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['subscription']?.trim() ?? flags['id']?.trim();
    if (id == null || id.isEmpty) {
      return {'error': 'Missing required flag: --subscription'};
    }

    final agentId = ChatAgentScope.agentId;
    final sub = EventBus.instance.findSubscription(id);
    if (sub == null) {
      return {'error': 'Subscription not found: $id'};
    }
    if (sub.agentId != agentId) {
      return {'error': 'Subscription belongs to another agent'};
    }

    EventBus.instance.removeSubscription(id);
    await LocalDatabaseService().deleteEventSubscription(id);

    return {'success': true, 'removed': id};
  }
}

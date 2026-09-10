import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../chat/chat_agent_scope.dart';

class EventsListSubscriptionsCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List current agent event subscriptions';

  @override
  String get usage => 'shepaw events list';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final subs = EventBus.instance.subscriptionsFor(ChatAgentScope.agentId);
    return {
      'count': subs.length,
      'subscriptions': subs
          .map((s) => {
                'id': s.id,
                'patterns': s.patterns
                    .map((p) => {
                          'type_glob': p.typeGlob,
                          'scope': p.scope,
                        })
                    .toList(),
                'delivery': s.delivery.wireValue,
                'persistent': s.persistent,
                'enabled': s.enabled,
                'created_seq': s.createdSeq,
              })
          .toList(),
    };
  }
}

import 'dart:convert';

import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../../../services/event/event_delivery.dart';
import '../../../services/event/event_pattern.dart';
import '../../../services/event/event_subscription_config_service.dart';
import '../../../services/local_database_service.dart';
import '../chat/chat_agent_scope.dart';

class EventsSubscribeCommand extends CliCommand {
  @override
  String get name => 'subscribe';

  @override
  String get description => 'Subscribe to event patterns (opt-in Pub/Sub)';

  @override
  String get usage =>
      'shepaw events subscribe --pattern "peer.pairing.*" [--delivery poll_only|passive|active] [--persist]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final pattern = flags['pattern']?.trim();
    if (pattern == null || pattern.isEmpty) {
      return {'error': 'Missing required flag: --pattern'};
    }

    final agentId = ChatAgentScope.agentId;
    final deny = await EventSubscriptionConfigService.instance
        .checkSubscribePermission(pattern: pattern, agentId: agentId);
    if (deny != null) return {'error': deny};

    final delivery = EventDelivery.fromWire(flags['delivery']) ??
        EventDelivery.pollOnly;
    final persist = flags.containsKey('persist');

    final sub = EventBus.instance.addSubscription(
      agentId: agentId,
      patterns: [EventPattern(typeGlob: pattern)],
      delivery: delivery,
      persistent: persist,
    );

    if (persist) {
      await LocalDatabaseService().upsertEventSubscription({
        'id': sub.id,
        'agent_id': agentId,
        'patterns_json': jsonEncode([
          {'type_glob': pattern, 'scope': {}},
        ]),
        'delivery': delivery.wireValue,
        'persistent': 1,
        'enabled': 1,
        'created_seq': sub.createdSeq,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    return {
      'success': true,
      'subscription_id': sub.id,
      'pattern': pattern,
      'delivery': delivery.wireValue,
      'persistent': persist,
    };
  }
}

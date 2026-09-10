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
      'shepaw events subscribe --pattern "peer.pairing.*" '
      '[--delivery poll_only|passive|active] [--persist] '
      '[--channel_id id] [--owner_id id] [--peer_id id] [--device_id id] [--agent_id id]';

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

    final scope = _scopeFromFlags(flags);

    final sub = EventBus.instance.addSubscription(
      agentId: agentId,
      patterns: [EventPattern(typeGlob: pattern, scope: scope)],
      delivery: delivery,
      persistent: persist,
    );

    if (persist) {
      await LocalDatabaseService().upsertEventSubscription({
        'id': sub.id,
        'agent_id': agentId,
        'patterns_json': jsonEncode([
          {'type_glob': pattern, 'scope': scope},
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
      if (scope.isNotEmpty) 'scope': scope,
      'delivery': delivery.wireValue,
      'persistent': persist,
    };
  }

  /// scope 过滤（缺省即通配）：--channel_id / --owner_id / --peer_id /
  /// --device_id / --agent_id。
  Map<String, String> _scopeFromFlags(Map<String, String> flags) {
    final scope = <String, String>{};
    void take(String key, String flag) {
      final raw = flags[flag]?.trim();
      if (raw != null && raw.isNotEmpty) scope[key] = raw;
    }

    take('channel_id', 'channel_id');
    if (!scope.containsKey('channel_id')) take('channel_id', 'channel');
    take('owner_id', 'owner_id');
    take('peer_id', 'peer_id');
    take('device_id', 'device_id');
    take('agent_id', 'agent_id');
    return scope;
  }
}

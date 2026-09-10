import 'dart:convert';

import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../../../services/event/event_scope.dart';
import '../../../services/event/event_subscription_config_service.dart';
import '../chat/chat_agent_scope.dart';

class EventsEmitCommand extends CliCommand {
  @override
  String get name => 'emit';

  @override
  String get description => 'Emit a custom agent event';

  @override
  String get usage =>
      'shepaw events emit --type agent.<id>.custom.task_done --payload "{...}" [--correlation cid]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final type = flags['type']?.trim();
    if (type == null || type.isEmpty) {
      return {'error': 'Missing required flag: --type'};
    }

    final agentId = ChatAgentScope.agentId;
    final deny = await EventSubscriptionConfigService.instance
        .checkEmitPermission(type: type, agentId: agentId);
    if (deny != null) return {'error': deny};

    Map<String, dynamic> payload;
    try {
      final raw = flags['payload'] ?? flags['json'] ?? '{}';
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      return {'error': 'Invalid --payload JSON: $e'};
    }
    if (!payload.containsKey('summary')) {
      payload['summary'] = type;
    }

    final correlation = flags['correlation']?.trim();
    final scope = EventScope(
      channelId: flags['channel_id'] ?? flags['channel'],
      agentId: agentId,
      ownerId: flags['owner_id'],
    );

    try {
      final result = EventBus.instance.emitAgent(
        agentId: agentId,
        type: type,
        payload: payload,
        scope: scope,
        correlationId: correlation?.isEmpty == true ? null : correlation,
      );
      return {'success': true, ...result.toJson()};
    } catch (e) {
      return {'error': e.toString()};
    }
  }
}

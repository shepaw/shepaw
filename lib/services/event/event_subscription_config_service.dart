import '../she_service.dart';
import '../cli_command_config_service.dart';

/// Permission checks for `events subscribe` / `events emit` (mirrors CLI config).
class EventSubscriptionConfigService {
  EventSubscriptionConfigService._();
  static final EventSubscriptionConfigService instance =
      EventSubscriptionConfigService._();

  Future<String?> checkSubscribePermission({
    required String pattern,
    required String agentId,
  }) async {
    final commandId = 'events.subscribe.$pattern';
    return CliCommandConfigService.instance.checkPermission(
      commandId,
      agentId: agentId,
    );
  }

  Future<String?> checkEmitPermission({
    required String type,
    required String agentId,
  }) async {
    if (type.startsWith('system.')) {
      return 'Agents cannot emit system events';
    }
    if (type.startsWith('agent.$agentId.')) {
      final commandId = 'events.emit.$type';
      return CliCommandConfigService.instance.checkPermission(
        commandId,
        agentId: agentId,
      );
    }
    if (type.startsWith('agent.')) {
      return 'Agents may only emit agent.$agentId.* events';
    }
    return 'Agents may only emit agent.$agentId.* events via CLI';
  }

  Future<String?> checkEventsCommandPermission({
    required String subcommand,
    required String agentId,
  }) async {
    final commandId = subcommand.isEmpty ? 'events' : 'events.$subcommand';
    return CliCommandConfigService.instance.checkPermission(
      commandId,
      agentId: agentId,
    );
  }

  bool isSheSeedSubscription(String agentId, String pattern) {
    return agentId == SheService.sheId && pattern == 'peer.pairing.inbound';
  }
}

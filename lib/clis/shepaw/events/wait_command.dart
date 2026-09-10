import '../../cli_base.dart';
import '../../../services/event/event_bus.dart';
import '../chat/chat_agent_scope.dart';

class EventsWaitCommand extends CliCommand {
  @override
  String get name => 'wait';

  @override
  String get description =>
      'Block until a matching event arrives (RPC; default timeout 30s)';

  @override
  String get usage =>
      'shepaw events wait --correlation <id> --type <event.type> [--timeout 30]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final correlation = flags['correlation']?.trim();
    final type = flags['type']?.trim();
    if (correlation == null || correlation.isEmpty) {
      return {'error': 'Missing required flag: --correlation'};
    }
    if (type == null || type.isEmpty) {
      return {'error': 'Missing required flag: --type'};
    }

    final timeoutSec = int.tryParse(flags['timeout'] ?? '30') ?? 30;
    if (timeoutSec <= 0 || timeoutSec > 120) {
      return {'error': '--timeout must be between 1 and 120 seconds'};
    }

    final agentId = ChatAgentScope.agentId;
    final bus = EventBus.instance;

    try {
      final lease = bus.openWaitLease(
        agentId: agentId,
        correlationId: correlation,
        typePatterns: [type],
        scopeFilter: _scopeFromFlags(flags),
        timeout: Duration(seconds: timeoutSec),
      );
      final envelope = await bus.waitOnLease(lease);
      return {
        'success': true,
        'event': envelope.toJson(),
      };
    } on CorrelationAlreadyWaitedException catch (e) {
      return {'error': e.toString()};
    } on WaitTimeoutException catch (e) {
      return {'error': e.toString(), 'timeout': true};
    }
  }

  EventScope? _scopeFromFlags(Map<String, String> flags) {
    final channelId = flags['channel_id'] ?? flags['channel'];
    final ownerId = flags['owner_id'];
    if ((channelId == null || channelId.isEmpty) &&
        (ownerId == null || ownerId.isEmpty)) {
      return null;
    }
    return EventScope(
      channelId: channelId?.trim().isEmpty == true ? null : channelId?.trim(),
      ownerId: ownerId?.trim().isEmpty == true ? null : ownerId?.trim(),
    );
  }
}

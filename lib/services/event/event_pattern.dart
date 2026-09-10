import 'event_scope.dart';
import 'event_type_matching.dart';

/// Subscription pattern: type glob + optional scope filter.
class EventPattern {
  final String typeGlob;
  final Map<String, String?> scope;

  const EventPattern({
    required this.typeGlob,
    this.scope = const {},
  });

  bool matchesType(String type) => typeMatchesPattern(typeGlob, type);

  bool matchesScope(EventScope eventScope) {
    if (scope.isEmpty) return true;
    final filter = EventScope(
      channelId: scope['channel_id'],
      agentId: scope['agent_id'],
      peerId: scope['peer_id'],
      deviceId: scope['device_id'],
      ownerId: scope['owner_id'],
    );
    return filter.contains(eventScope);
  }
}

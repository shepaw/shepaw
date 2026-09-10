import 'event_delivery.dart';
import 'event_pattern.dart';
import 'event_scope.dart';

/// Agent subscription to event patterns (long-lived Pub/Sub).
class EventSubscription {
  final String id;
  final String agentId;
  final List<EventPattern> patterns;
  final EventDelivery delivery;
  final String? channelBinding;
  final bool persistent;
  final DateTime? expiresAt;
  final int debounceMs;
  final int maxBatch;
  final bool enabled;
  final int createdSeq;

  const EventSubscription({
    required this.id,
    required this.agentId,
    required this.patterns,
    this.delivery = EventDelivery.pollOnly,
    this.channelBinding,
    this.persistent = false,
    this.expiresAt,
    this.debounceMs = 0,
    this.maxBatch = 10,
    this.enabled = true,
    required this.createdSeq,
  });

  bool get isExpired {
    final exp = expiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp);
  }

  bool matches({
    required String type,
    required EventScope eventScope,
    required int eventSeq,
  }) {
    if (!enabled || isExpired) return false;
    if (eventSeq < createdSeq) return false;

    for (final pattern in patterns) {
      if (!pattern.matchesType(type)) continue;
      if (!pattern.matchesScope(eventScope)) continue;
      if (channelBinding != null &&
          channelBinding != '*' &&
          eventScope.channelId != channelBinding) {
        continue;
      }
      return true;
    }
    return false;
  }
}

/// How matched events are delivered to an agent subscription.
enum EventDelivery {
  /// Inbox only; agent polls via `events inbox` / `events wait`.
  pollOnly('poll_only'),

  /// Written to inbox and merged into the agent's next turn context.
  passive('passive'),

  /// Inbox + schedules a notify-only perception turn (P1+).
  active('active');

  const EventDelivery(this.wireValue);

  final String wireValue;

  static EventDelivery? fromWire(String? value) {
    if (value == null || value.isEmpty) return null;
    for (final d in EventDelivery.values) {
      if (d.wireValue == value) return d;
    }
    return null;
  }
}

/// Default delivery policy registered on an [EventTypeDefinition].
typedef EventDeliveryPolicy = EventDelivery;

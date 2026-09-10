import 'event_scope.dart';

/// Canonical event record flowing through [EventBus].
class EventEnvelope {
  final String id;
  final String type;
  final String source;
  final String? correlationId;
  final String? causationId;
  final int seq;
  final DateTime at;
  final Map<String, dynamic> payload;
  final EventScope scope;
  final String? dedupeKey;

  const EventEnvelope({
    required this.id,
    required this.type,
    required this.source,
    this.correlationId,
    this.causationId,
    required this.seq,
    required this.at,
    required this.payload,
    this.scope = const EventScope(),
    this.dedupeKey,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'source': source,
        if (correlationId != null) 'correlation_id': correlationId,
        if (causationId != null) 'causation_id': causationId,
        'seq': seq,
        'at': at.toIso8601String(),
        'payload': payload,
        'scope': scope.toJson(),
        if (dedupeKey != null) 'dedupe_key': dedupeKey,
      };

  EventEnvelope copyWith({
    String? id,
    String? type,
    String? source,
    String? correlationId,
    String? causationId,
    int? seq,
    DateTime? at,
    Map<String, dynamic>? payload,
    EventScope? scope,
    String? dedupeKey,
  }) {
    return EventEnvelope(
      id: id ?? this.id,
      type: type ?? this.type,
      source: source ?? this.source,
      correlationId: correlationId ?? this.correlationId,
      causationId: causationId ?? this.causationId,
      seq: seq ?? this.seq,
      at: at ?? this.at,
      payload: payload ?? this.payload,
      scope: scope ?? this.scope,
      dedupeKey: dedupeKey ?? this.dedupeKey,
    );
  }
}

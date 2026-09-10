import 'event_envelope.dart';

/// Per-agent inbox with ack tracking (P0 in-memory).
class EventInboxStore {
  final Map<String, List<InboxEntry>> _inboxes = {};

  void write(
    String agentId,
    EventEnvelope event, {
    String via = 'subscription',
    String? delivery,
  }) {
    final list = _inboxes.putIfAbsent(agentId, () => []);
    if (list.any((e) => e.event.id == event.id)) return;
    list.add(InboxEntry(
      event: event,
      deliveredAt: DateTime.now(),
      deliveredVia: via,
      delivery: delivery,
    ));
    list.sort((a, b) => a.event.seq.compareTo(b.event.seq));
  }

  /// 将指定事件的 inbox 档位改为 [newDelivery]（如 active → passive 降级）。
  void reclassifyDelivery(
    String agentId,
    Iterable<String> eventIds,
    String newDelivery,
  ) {
    final ids = eventIds.toSet();
    final list = _inboxes[agentId];
    if (list == null) return;
    for (final entry in list) {
      if (ids.contains(entry.event.id)) {
        entry.delivery = newDelivery;
      }
    }
  }

  /// 未 ack 的 [delivery] 档位事件（passive 上下文注入用），按 seq 升序。
  List<InboxEntry> unreadByDelivery(
    String agentId,
    String delivery, {
    int limit = 5,
  }) {
    final list = _inboxes[agentId] ?? const [];
    return list
        .where((e) => e.ackedAt == null && e.delivery == delivery)
        .take(limit)
        .toList();
  }

  List<InboxEntry> inboxFor(
    String agentId, {
    int cursor = 0,
    int limit = 20,
    bool unreadOnly = false,
    String? correlationId,
    String? typePattern,
  }) {
    final all = _inboxes[agentId] ?? const [];
    var filtered = all.where((e) => e.event.seq > cursor);
    if (unreadOnly) {
      filtered = filtered.where((e) => e.ackedAt == null);
    }
    if (correlationId != null) {
      filtered = filtered.where((e) => e.event.correlationId == correlationId);
    }
    if (typePattern != null && typePattern.isNotEmpty) {
      filtered = filtered.where((e) {
        // Simple prefix/glob handled by caller if needed; here exact or prefix.*
        if (typePattern.endsWith('.*')) {
          final prefix = typePattern.substring(0, typePattern.length - 2);
          return e.event.type == prefix || e.event.type.startsWith('$prefix.');
        }
        return e.event.type == typePattern;
      });
    }
    return filtered.take(limit).toList();
  }

  int ack(String agentId, {String? eventId, String? correlationId}) {
    final list = _inboxes[agentId];
    if (list == null) return 0;
    var count = 0;
    final now = DateTime.now();
    for (final entry in list) {
      if (entry.ackedAt != null) continue;
      final matchId = eventId != null && entry.event.id == eventId;
      final matchCorr = correlationId != null &&
          entry.event.correlationId == correlationId;
      if (matchId || matchCorr) {
        entry.ackedAt = now;
        count++;
      }
    }
    return count;
  }

  void reset() => _inboxes.clear();
}

class InboxEntry {
  final EventEnvelope event;
  final DateTime deliveredAt;
  final String deliveredVia;

  /// 投递档位（`EventDelivery.wireValue`）；wait 路径为 null；可降级改写。
  String? delivery;
  DateTime? ackedAt;

  InboxEntry({
    required this.event,
    required this.deliveredAt,
    required this.deliveredVia,
    this.delivery,
  });

  Map<String, dynamic> toJson() => {
        'event': event.toJson(),
        'delivered_at': deliveredAt.toIso8601String(),
        'delivered_via': deliveredVia,
        if (delivery != null) 'delivery': delivery,
        'acked': ackedAt != null,
        if (event.correlationId != null)
          'correlation_id': event.correlationId,
      };
}

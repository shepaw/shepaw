import 'dart:convert';

import '../local_database_service.dart';
import 'event_bus.dart';
import 'event_delivery.dart';
import 'event_pattern.dart';

/// Restore persistent event subscriptions from SQLite (P3).
Future<void> loadPersistedEventSubscriptions({EventBus? bus}) async {
  final target = bus ?? EventBus.instance;
  final rows = await LocalDatabaseService().queryAllEventSubscriptions();
  for (final row in rows) {
    if ((row['enabled'] as int? ?? 1) == 0) continue;
    final agentId = row['agent_id'] as String?;
    if (agentId == null) continue;
    final id = row['id'] as String?;
    if (id != null && target.findSubscription(id) != null) continue;

    List<EventPattern> patterns;
    try {
      final raw = jsonDecode(row['patterns_json'] as String) as List;
      patterns = raw.map((p) {
        final map = (p as Map).cast<String, dynamic>();
        final scopeRaw = (map['scope'] as Map?)?.cast<String, dynamic>() ?? {};
        return EventPattern(
          typeGlob: map['type_glob'] as String? ?? '*',
          scope: scopeRaw.map((k, v) => MapEntry(k, v?.toString())),
        );
      }).toList();
    } catch (_) {
      continue;
    }

    final delivery = EventDelivery.fromWire(row['delivery'] as String?) ??
        EventDelivery.pollOnly;

    target.addSubscription(
      subscriptionId: id,
      agentId: agentId,
      patterns: patterns,
      delivery: delivery,
      persistent: (row['persistent'] as int? ?? 1) == 1,
      createdSeq: row['created_seq'] as int?,
    );
  }
}

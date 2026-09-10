import 'event_bus_store.dart';
import 'event_delivery.dart';
import 'event_envelope.dart';
import 'event_inbox_store.dart';
import 'event_subscription.dart';
import 'perception_scheduler.dart';
import 'wait_lease.dart';

/// Delivery target produced by routing.
class DispatchTarget {
  final String agentId;
  final EventDelivery delivery;
  final String mode; // wait | subscription
  final String? subscriptionId;

  const DispatchTarget({
    required this.agentId,
    required this.delivery,
    required this.mode,
    this.subscriptionId,
  });
}

class EventRouter {
  EventRouter({
    required this.busStore,
    required this.inboxStore,
    required this.perceptionScheduler,
  });

  final EventBusStore busStore;
  final EventInboxStore inboxStore;
  final PerceptionScheduler perceptionScheduler;

  /// Returns true when wait lease consumed the event (early-return path).
  bool dispatch(
    EventEnvelope event, {
    required Iterable<WaitLease> activeLeases,
    required Iterable<EventSubscription> subscriptions,
  }) {
    // 1. WaitLease priority
    for (final lease in activeLeases) {
      if (!lease.matches(event)) continue;
      lease.complete(event);
      inboxStore.write(lease.agentId, event, via: 'wait');
      if (lease.correlationId != null) {
        return true; // suppress subscription active wake for this correlation
      }
      break; // only first matching lease
    }

    // 2. Subscriptions
    final targets = <DispatchTarget>[];
    for (final sub in subscriptions) {
      if (!sub.matches(
        type: event.type,
        eventScope: event.scope,
        eventSeq: event.seq,
      )) {
        continue;
      }
      targets.add(DispatchTarget(
        agentId: sub.agentId,
        delivery: sub.delivery,
        mode: 'subscription',
        subscriptionId: sub.id,
      ));
    }

    // 3. Router-level dedupe per agent
    final dedupeKey = event.dedupeKey;
    final deliveredAgents = <String>{};

    for (final target in targets) {
      if (deliveredAgents.contains(target.agentId)) continue;

      if (dedupeKey != null) {
        final agentDedupe = '$dedupeKey::${target.agentId}';
        if (busStore.recentDedupeOriginalId(agentDedupe) != null) {
          continue;
        }
        busStore.recordDedupe(agentDedupe, event.id);
      }

      deliveredAgents.add(target.agentId);
      inboxStore.write(target.agentId, event, via: target.mode);

      if (target.delivery == EventDelivery.active) {
        perceptionScheduler.schedule(
          agentId: target.agentId,
          channelId: event.scope.channelId ?? '',
          events: [event],
        );
      }
      // passive: inbox only for P0; context injection deferred to P1+
    }

    return false;
  }
}

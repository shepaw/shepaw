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
    var consumed = false;

    // 1. WaitLease priority
    // RPC 命中即视为该 agent 已消费：其订阅不再二次投递（含 active 唤醒），
    // 但 **不** 影响其他 agent 的订阅。
    //
    // 不带 correlation 的裸 wait（RFC §8.1 允许 `wait` 省略 --correlation）
    // 同样算已消费：否则同一事件会既完成 wait、又触发 active 感知回合。
    final waitedAgents = <String>{};
    for (final lease in activeLeases) {
      if (!lease.matches(event)) continue;
      lease.complete(event);
      inboxStore.write(lease.agentId, event, via: 'wait');
      waitedAgents.add(lease.agentId);
      break; // only first matching lease
    }
    if (waitedAgents.isNotEmpty) consumed = true;

    // 2. Subscriptions
    final targets = <DispatchTarget>[];
    for (final sub in subscriptions) {
      if (waitedAgents.contains(sub.agentId)) continue;
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
      inboxStore.write(
        target.agentId,
        event,
        via: target.mode,
        delivery: target.delivery.wireValue,
      );

      // active：debounce 后唤醒 notify-only 回合。
      // passive：仅入 inbox，由 [EventBus.buildPassiveContext] 并入该 agent
      // 的下一回合 context。
      if (target.delivery == EventDelivery.active) {
        perceptionScheduler.schedule(
          agentId: target.agentId,
          channelId: event.scope.channelId ?? '',
          events: [event],
        );
      }
    }

    return consumed;
  }
}

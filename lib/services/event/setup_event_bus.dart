import 'event_bus.dart';
import 'event_perception_service.dart';
import 'group_event_types.dart';
import 'peer_event_provider.dart';
import 'load_event_subscriptions.dart';
import 'workflow_event_types.dart';

/// Bootstrap hook: register built-in types + She seed on the global [EventBus].
void setupEventBus({EventBus? bus}) {
  final target = bus ?? EventBus.instance;
  PeerEventProvider.registerTypes(target.registry);
  registerGroupEventTypes(target.registry);
  registerWorkflowEventTypes(target.registry);
  registerStoreEventTypes(target.registry);
  registerChatEventTypes(target.registry);
  PeerEventProvider.seedSheInboundSubscription(target);
  // 必须显式传 target：`EventBus.instance` 在 bootstrap 期间可能尚未 configure，
  // 直接取单例会把感知回调绑到另一个（孤儿）bus 上，导致 active 唤醒永不触发。
  wireEventPerception(target);
}

/// Call after DB is ready (AppBootstrap).
Future<void> setupEventBusAfterDb({EventBus? bus}) async {
  await loadPersistedEventSubscriptions(bus: bus);
}

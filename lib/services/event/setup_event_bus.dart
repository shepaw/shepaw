import 'event_bus.dart';
import 'event_delivery.dart';
import 'event_namespace_registry.dart';
import 'event_perception_service.dart';
import 'group_event_types.dart';
import 'peer_event_provider.dart';
import 'load_event_subscriptions.dart';
import 'workflow_event_types.dart';

/// Bootstrap hook: register built-in types + She seed on the global [EventBus].
void setupEventBus({EventBus? bus}) {
  final target = bus ?? EventBus.instance;
  registerP0BuiltinEventTypes(target.registry);
  PeerEventProvider.registerTypes(target.registry);
  registerGroupEventTypes(target.registry);
  registerWorkflowEventTypes(target.registry);
  registerStoreEventTypes(target.registry);
  registerChatEventTypes(target.registry);
  PeerEventProvider.seedSheInboundSubscription(target);
  wireEventPerception();
}

/// Call after DB is ready (AppBootstrap).
Future<void> setupEventBusAfterDb({EventBus? bus}) async {
  await loadPersistedEventSubscriptions(bus: bus);
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_envelope.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/event_type_definition.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/setup_event_bus.dart';

void main() {
  test('perceptionCliAllowlistForEvents unions type-specific lists', () {
    final registry = EventNamespaceRegistry.instance;
    registry.register(const EventTypeDefinition(
      id: 'test.perception.a',
      description: 'a',
      perceptionCliAllowlist: {'peer.accept', 'events.ack'},
    ));
    registry.register(const EventTypeDefinition(
      id: 'test.perception.b',
      description: 'b',
      perceptionCliAllowlist: {'peer.reject'},
    ));
    registry.register(const EventTypeDefinition(
      id: 'test.perception.unrestricted',
      description: 'none',
    ));

    final allow = perceptionCliAllowlistForEvents(
      [
        EventEnvelope(
          id: 'e1',
          type: 'test.perception.a',
          source: 'system:test',
          seq: 1,
          at: DateTime.now(),
          payload: const {},
          scope: const EventScope(),
        ),
        EventEnvelope(
          id: 'e2',
          type: 'test.perception.b',
          source: 'system:test',
          seq: 2,
          at: DateTime.now(),
          payload: const {},
          scope: const EventScope(),
        ),
      ],
      registry,
    );

    expect(allow, containsAll(['peer.accept', 'peer.reject', 'events.ack']));
  });

  test('peer.pairing.inbound registers perception CLI allowlist', () {
    final bus = EventBus();
    setupEventBus(bus: bus);
    final def = bus.registry.get('peer.pairing.inbound');
    expect(def, isNotNull);
    expect(def!.perceptionCliAllowlist, contains('peer.accept'));
    expect(def.perceptionCliAllowlist, contains('events.ack'));
  });
}

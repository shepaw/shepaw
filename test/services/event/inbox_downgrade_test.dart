import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/setup_event_bus.dart';

void main() {
  test('downgradeActiveInboxToPassive makes events visible in passive context',
      () {
    final bus = EventBus();
    setupEventBus(bus: bus);
    bus.addSubscription(
      agentId: 'agent_down',
      patterns: [const EventPattern(typeGlob: 'peer.pairing.inbound')],
      delivery: EventDelivery.active,
    );

    final result = bus.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.inbound',
      payload: {
        'summary': '设备 Test 请求配对',
        'device_name': 'Test',
        'fingerprint': 'fp_down',
      },
      scope: const EventScope(ownerId: 'owner_down'),
      correlationId: 'cid_down',
    );

    expect(bus.buildPassiveContext('agent_down'), isNull);

    bus.downgradeActiveInboxToPassive('agent_down', [result.id]);

    final context = bus.buildPassiveContext('agent_down');
    expect(context, isNotNull);
    expect(context, contains('设备 Test 请求配对'));
  });
}

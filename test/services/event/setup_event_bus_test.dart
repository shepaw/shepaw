import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/setup_event_bus.dart';

void main() {
  test('setupEventBus binds perception to the bus it was given', () {
    final bus = EventBus();
    setupEventBus(bus: bus);

    // 回归：wireEventPerception 曾取 `EventBus.instance`（此时可能尚未
    // configure），把感知回调绑到另一个孤儿 bus 上，active 唤醒永不触发。
    expect(bus.perceptionScheduler.onSchedule, isNotNull);
  });

  test('resetRuntimeState clears state but keeps perception binding', () {
    final bus = EventBus();
    setupEventBus(bus: bus);
    bus.addSubscription(
      agentId: 'agent_reset',
      patterns: [const EventPattern(typeGlob: 'peer.pairing.inbound')],
      delivery: EventDelivery.pollOnly,
    );
    bus.emitSystem(
      systemDomain: 'peer',
      type: 'peer.pairing.inbound',
      payload: {'summary': 'x', 'fingerprint': 'fp'},
      scope: const EventScope(ownerId: 'owner_1'),
      correlationId: 'cid_reset',
    );
    expect(bus.inboxFor('agent_reset'), isNotEmpty);

    final scheduler = bus.perceptionScheduler;
    bus.resetRuntimeState();

    expect(bus.allSubscriptions, isEmpty);
    expect(bus.inboxFor('agent_reset'), isEmpty);
    expect(bus.currentSeq, 0);
    // 感知回调必须保留，否则重置后到下次启动前 active 唤醒失效
    expect(scheduler.onSchedule, isNotNull);
  });

  test('setupEventBus does not register P0 test types', () {
    final bus = EventBus();
    setupEventBus(bus: bus);

    expect(bus.registry.get('test.event.ping'), isNull);
    expect(bus.registry.get('test.event.pong'), isNull);
    expect(bus.registry.get('peer.pairing.inbound'), isNotNull);
  });
}

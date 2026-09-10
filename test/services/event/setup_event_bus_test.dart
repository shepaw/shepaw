import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/setup_event_bus.dart';

void main() {
  test('setupEventBus binds perception to the bus it was given', () {
    final bus = EventBus();
    setupEventBus(bus: bus);

    // 回归：wireEventPerception 曾取 `EventBus.instance`（此时可能尚未
    // configure），把感知回调绑到另一个孤儿 bus 上，active 唤醒永不触发。
    expect(bus.perceptionScheduler.onSchedule, isNotNull);
  });

  test('setupEventBus does not register P0 test types', () {
    final bus = EventBus();
    setupEventBus(bus: bus);

    expect(bus.registry.get('test.event.ping'), isNull);
    expect(bus.registry.get('test.event.pong'), isNull);
    expect(bus.registry.get('peer.pairing.inbound'), isNotNull);
  });
}

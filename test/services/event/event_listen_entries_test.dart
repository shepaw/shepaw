import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_pattern.dart';

void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
  });

  test('listenEntriesFor includes subscription patterns and wait leases', () {
    bus.addSubscription(
      agentId: 'a1',
      patterns: const [
        EventPattern(typeGlob: 'peer.pairing.*'),
        EventPattern(typeGlob: 'store.file.changed'),
      ],
      delivery: EventDelivery.active,
    );
    bus.openWaitLease(
      agentId: 'a1',
      correlationId: 'cid1',
      typePatterns: ['peer.pairing.inbound'],
    );
    bus.addSubscription(
      agentId: 'a2',
      patterns: const [EventPattern(typeGlob: 'other.*')],
    );

    final entries = bus.listenEntriesFor(['a1']);
    expect(entries, hasLength(3));
    expect(
      entries.where((e) => e.kind == AgentEventListenKind.subscription),
      hasLength(2),
    );
    expect(entries.where((e) => e.isWait), hasLength(1));
    expect(entries.where((e) => e.isWait).single.correlationId, 'cid1');
    expect(bus.listenEntriesFor(['a3']), isEmpty);
  });

  test('disabled and expired subscriptions are omitted', () {
    bus.addSubscription(
      agentId: 'a1',
      patterns: const [EventPattern(typeGlob: 'x')],
      enabled: false,
    );
    bus.addSubscription(
      agentId: 'a1',
      patterns: const [EventPattern(typeGlob: 'y')],
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(bus.listenEntriesFor(['a1']), isEmpty);
  });

  test('listenListenable ticks when subscriptions or waits change', () {
    var ticks = 0;
    bus.listenListenable.addListener(() => ticks++);

    bus.addSubscription(
      agentId: 'a1',
      patterns: const [EventPattern(typeGlob: 'x')],
    );
    expect(ticks, 1);

    final id = bus.allSubscriptions.single.id;
    bus.removeSubscription(id);
    expect(ticks, 2);

    bus.openWaitLease(
      agentId: 'a1',
      typePatterns: ['x'],
    );
    expect(ticks, 3);
    expect(bus.listenEntriesFor(['a1']), hasLength(1));
  });
}

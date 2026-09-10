import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
  });

  test('wait lease matches only same correlation', () async {
    const cidA = 'cid_a';
    const cidB = 'cid_b';

    final lease = bus.openWaitLease(
      agentId: 'agent_test',
      correlationId: cidA,
      typePatterns: ['test.event.pong'],
    );

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'wrong'},
      correlationId: cidB,
    );

    await Future<void>.delayed(Duration.zero);
    expect(lease.completed, false);

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'ok'},
      correlationId: cidA,
    );

    final event = await lease.completer.future;
    expect(event.correlationId, cidA);
  });

  test('lease early-return suppresses active subscription for correlation', () {
    var scheduleCount = 0;
    bus.perceptionScheduler.onSchedule = (_, __) => scheduleCount++;

    bus.addSubscription(
      agentId: SheService.sheId,
      patterns: [const EventPattern(typeGlob: 'test.event.pong')],
      delivery: EventDelivery.active,
    );

    bus.openWaitLease(
      agentId: SheService.sheId,
      correlationId: 'cid_x',
      typePatterns: ['test.event.pong'],
    );

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'hit'},
      correlationId: 'cid_x',
    );

    expect(scheduleCount, 0);
  });

  test('subscription without match keeps inbox empty', () {
    bus.addSubscription(
      agentId: 'agent_a',
      patterns: [const EventPattern(typeGlob: 'test.event.ping')],
    );

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'nope'},
      correlationId: 'cid_1',
    );

    expect(bus.inboxFor('agent_a'), isEmpty);
  });

  test('historical events filtered by createdSeq', () {
    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.ping',
      payload: {'summary': 'old'},
      correlationId: 'cid_old',
    );

    bus.addSubscription(
      agentId: 'agent_late',
      patterns: [const EventPattern(typeGlob: 'test.event.ping')],
    );

    expect(bus.inboxFor('agent_late'), isEmpty);
  });
}

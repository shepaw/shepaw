import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';

void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
    bus.addSubscription(
      agentId: 'agent_dedupe',
      patterns: [const EventPattern(typeGlob: 'test.event.pong')],
    );
  });

  test('duplicate emit still completes wait lease', () async {
    const cid = 'cid_dedupe_wait';

    final lease = bus.openWaitLease(
      agentId: 'agent_wait',
      correlationId: cid,
      typePatterns: ['test.event.pong'],
    );

    final r1 = bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'first', 'fingerprint': 'fp1'},
      correlationId: cid,
    );

    final r2 = bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'dup', 'fingerprint': 'fp1'},
      correlationId: cid,
    );

    expect(r1.deduplicated, false);
    expect(r2.deduplicated, true);

    final event = await lease.completer.future;
    expect(event.correlationId, cid);
  });

  test('router dedupe prevents duplicate inbox for subscription', () {
    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'a', 'fingerprint': 'x'},
      correlationId: 'c1',
    );
    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'b', 'fingerprint': 'x'},
      correlationId: 'c1',
    );

    expect(bus.inboxFor('agent_dedupe').length, 1);
  });
}

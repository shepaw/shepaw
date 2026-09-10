import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/wait_lease.dart';

void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
  });

  test('second wait on same correlation throws (cross-agent deny)', () {
    bus.openWaitLease(
      agentId: 'a1',
      correlationId: 'cid_cross',
      typePatterns: ['test.event.ping'],
    );

    expect(
      () => bus.openWaitLease(
        agentId: 'a2',
        correlationId: 'cid_cross',
        typePatterns: ['test.event.ping'],
      ),
      throwsA(isA<CorrelationAlreadyWaitedException>()),
    );
  });

  test('second wait on same correlation throws (same agent)', () {
    bus.openWaitLease(
      agentId: 'a1',
      correlationId: 'cid_dup',
      typePatterns: ['test.event.ping'],
    );

    expect(
      () => bus.openWaitLease(
        agentId: 'a1',
        correlationId: 'cid_dup',
        typePatterns: ['test.event.ping'],
      ),
      throwsA(isA<CorrelationAlreadyWaitedException>()),
    );
  });

  test('waitOnLease times out', () async {
    final lease = bus.openWaitLease(
      agentId: 'a1',
      correlationId: 'cid_timeout',
      typePatterns: ['test.event.ping'],
      timeout: const Duration(milliseconds: 50),
    );

    expect(
      bus.waitOnLease(lease),
      throwsA(isA<WaitTimeoutException>()),
    );
  });

  test('seqAtOpen ignores events emitted before lease opened', () async {
    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.ping',
      payload: {'summary': 'before'},
      correlationId: 'cid_seq',
    );

    final lease = bus.openWaitLease(
      agentId: 'a1',
      correlationId: 'cid_seq',
      typePatterns: ['test.event.ping'],
      timeout: const Duration(milliseconds: 100),
    );

    expect(
      bus.waitOnLease(lease),
      throwsA(isA<WaitTimeoutException>()),
    );
  });
}

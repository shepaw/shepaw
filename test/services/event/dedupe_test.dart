import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_bus_store.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/workflow_event_types.dart';

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

  test('store.file.changed 同文件同变更在窗口内去重', () {
    registerStoreEventTypes(bus.registry);
    bus.addSubscription(
      agentId: 'agent_store',
      patterns: [const EventPattern(typeGlob: 'store.file.changed')],
    );

    Map<String, dynamic> emit(String change) => bus.emitSystem(
          systemDomain: 'store',
          type: 'store.file.changed',
          payload: {
            'summary': 'notes.md 已修改',
            'uri': 'store://notes.md',
            'change': change,
          },
          scope: const EventScope(ownerId: 'owner_dedupe'),
        ).toJson();

    final first = emit('modified');
    final repeat = emit('modified');
    final different = emit('deleted');

    expect(first['deduplicated'], isNot(true));
    expect(repeat['deduplicated'], true);
    expect(different['deduplicated'], isNot(true));
    expect(bus.inboxFor('agent_store').length, 2);
  });

  test('duplicate emit dropped when original evicted from log', () {
    final smallStore = EventBusStore(maxLogEntries: 2);
    final smallBus = EventBus(busStore: smallStore);
    registerP0BuiltinEventTypes(smallBus.registry);
    smallBus.addSubscription(
      agentId: 'agent_evict',
      patterns: [const EventPattern(typeGlob: 'test.event.pong')],
    );

    const cid = 'cid_evict';
    final r1 = smallBus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'first', 'fingerprint': 'fp_evict'},
      correlationId: cid,
    );
    smallBus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'second', 'fingerprint': 'fp2'},
      correlationId: 'cid_other',
    );
    smallBus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'third', 'fingerprint': 'fp3'},
      correlationId: 'cid_third',
    );

    final rDup = smallBus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'dup', 'fingerprint': 'fp_evict'},
      correlationId: cid,
    );

    expect(r1.deduplicated, false);
    expect(rDup.deduplicated, true);
    // 重复 emit 被丢弃，inbox 仍只有三次合法投递（不含 dup）。
    expect(smallBus.inboxFor('agent_evict').length, 3);
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

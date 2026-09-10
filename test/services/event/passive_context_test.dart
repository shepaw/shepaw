import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';

void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
  });

  test('passive inbox events appear in next-turn context until acked', () {
    bus.addSubscription(
      agentId: 'agent_p',
      patterns: [const EventPattern(typeGlob: 'test.event.pong')],
      delivery: EventDelivery.passive,
    );

    expect(bus.buildPassiveContext('agent_p'), isNull);

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': '配对已完成', 'fingerprint': 'fp1'},
      correlationId: 'cid_p1',
    );

    final context = bus.buildPassiveContext('agent_p');
    expect(context, isNotNull);
    expect(context, contains('配对已完成'));
    expect(context, contains('cid_p1'));

    bus.ackInbox('agent_p', correlationId: 'cid_p1');
    expect(bus.buildPassiveContext('agent_p'), isNull);
  });

  test('poll_only and active deliveries stay out of passive context', () {
    bus.addSubscription(
      agentId: 'agent_q',
      patterns: [const EventPattern(typeGlob: 'test.event.*')],
      delivery: EventDelivery.pollOnly,
    );
    bus.addSubscription(
      agentId: 'agent_a',
      patterns: [const EventPattern(typeGlob: 'test.event.*')],
      delivery: EventDelivery.active,
    );

    bus.emitSystem(
      systemDomain: 'test',
      type: 'test.event.pong',
      payload: {'summary': 'x', 'fingerprint': 'fp2'},
      correlationId: 'cid_x',
    );

    expect(bus.buildPassiveContext('agent_q'), isNull);
    expect(bus.buildPassiveContext('agent_a'), isNull);
    // 但仍各自入 inbox（poll_only 供轮询，active 已独立唤醒）
    expect(bus.inboxFor('agent_q').length, 1);
    expect(bus.inboxFor('agent_a').length, 1);
  });
}

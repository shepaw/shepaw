import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_delivery.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';
import 'package:shepaw/services/event/event_pattern.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/event_type_definition.dart';

void main() {
  group('P4 registry 隔离与回收', () {
    test('registry 可构造隔离实例（EventBus(registry:) 才有意义）', () {
      final a = EventNamespaceRegistry();
      final b = EventNamespaceRegistry();
      a.register(const EventTypeDefinition(id: 'x.y', description: 'x'));
      expect(a.get('x.y'), isNotNull);
      expect(b.get('x.y'), isNull);
      expect(a.get('x.y'), isNot(same(EventNamespaceRegistry.instance)));
    });

    test('resetRuntimeState 回收自动注册的 agent 类型，保留内置类型', () {
      final bus = EventBus(registry: EventNamespaceRegistry());
      bus.registry.register(const EventTypeDefinition(
        id: 'builtin.keep',
        description: 'builtin',
      ));

      bus.emitAgent(
        agentId: 'ag1',
        type: 'agent.ag1.dynamic.one',
        payload: const {'summary': 'x'},
      );
      expect(bus.registry.get('agent.ag1.dynamic.one'), isNotNull);

      bus.resetRuntimeState();

      expect(bus.registry.get('agent.ag1.dynamic.one'), isNull,
          reason: '自动注册类型必须回收，避免长跑进程类型表单调增长');
      expect(bus.registry.get('builtin.keep'), isNotNull,
          reason: '内置类型必须保留，否则重置后 emitSystem 会抛 unknown type');
    });
  });

  group('P5 裸 wait 不得与 active 订阅双投递', () {
    test('无 correlation 的 wait 同样抑制该 agent 的 active 唤醒', () async {
      final bus = EventBus(registry: EventNamespaceRegistry());
      bus.registry.register(const EventTypeDefinition(
        id: 'probe.ping',
        description: 'probe',
        defaultDelivery: EventDelivery.active,
      ));

      var wakes = 0;
      bus.perceptionScheduler.debounce = const Duration(milliseconds: 1);
      bus.perceptionScheduler.onSchedule = (_, __, ___) async => wakes++;

      bus.addSubscription(
        agentId: 'a1',
        patterns: [const EventPattern(typeGlob: 'probe.ping')],
        delivery: EventDelivery.active,
      );

      final lease = bus.openWaitLease(
        agentId: 'a1',
        typePatterns: ['probe.ping'],
      );
      bus.emitSystem(
        systemDomain: 'probe',
        type: 'probe.ping',
        payload: const {'summary': 'hello'},
      );
      final event = await bus.waitOnLease(lease);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(event.type, 'probe.ping');
      expect(bus.inboxFor('a1').length, 1);
      expect(wakes, 0, reason: 'wait 已消费该事件，不应再触发 active 感知回合');
    });
  });

  group('P6 inbox --pattern 与订阅同一套 glob', () {
    test('同深度 * 通配在 inbox 过滤中生效', () {
      final bus = EventBus(registry: EventNamespaceRegistry());
      for (final id in ['chat.a.failed', 'chat.a.completed']) {
        bus.registry.register(EventTypeDefinition(
          id: id,
          description: id,
          defaultDelivery: EventDelivery.pollOnly,
        ));
        bus.emitSystem(
          systemDomain: 'chat',
          type: id,
          payload: const {'summary': 'x'},
          scope: const EventScope(ownerId: 'o1'),
        );
      }
      bus.inboxStore.write('a1', bus.busStore.log.first);
      bus.inboxStore.write('a1', bus.busStore.log.last);

      final matched = bus.inboxFor('a1', typePattern: 'chat.*.failed');
      expect(matched.length, 1);
      expect(matched.single.event.type, 'chat.a.failed');
    });
  });
}

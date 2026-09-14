import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_bus.dart';
import 'package:shepaw/services/event/event_namespace_registry.dart';

/// 事件管理页依赖的两个新增只读/通知接口。
void main() {
  late EventBus bus;

  setUp(() {
    bus = EventBus();
    registerP0BuiltinEventTypes(bus.registry);
  });

  group('activeWaitLeases', () {
    test('列出刚开的 lease', () {
      bus.openWaitLease(
        agentId: 'a1',
        correlationId: 'cid_1',
        typePatterns: ['test.event.ping'],
      );

      expect(bus.activeWaitLeases, hasLength(1));
      expect(bus.activeWaitLeases.single.agentId, 'a1');
      expect(bus.activeWaitLeases.single.correlationId, 'cid_1');
    });

    test('cancel 后不再列出，等待方收到取消异常', () async {
      final lease = bus.openWaitLease(
        agentId: 'a1',
        typePatterns: ['test.event.ping'],
      );
      final waiter = bus.waitOnLease(lease);

      bus.cancelWaitLease(lease.leaseId);

      await expectLater(waiter, throwsA(isA<WaitCancelledException>()));
      expect(bus.activeWaitLeases, isEmpty);
    });

    test('已过期的 lease 从列表里滤掉（而不是留在裸 _leases 里）', () {
      bus.openWaitLease(
        agentId: 'a1',
        typePatterns: ['test.event.ping'],
        timeout: Duration.zero,
      );

      // 无人 await 的 lease 过期后 completed/cancelled 仍是 false，
      // 只有 isExpired 为真 —— 裸 `_leases` 会把它当成活的。
      expect(bus.activeWaitLeases, isEmpty);
    });

    test('不同 agent 的 lease 都列出，由调用方按 agentId 过滤', () {
      bus.openWaitLease(
        agentId: 'a1',
        typePatterns: ['test.event.ping'],
      );
      bus.openWaitLease(
        agentId: 'a2',
        typePatterns: ['test.event.pong'],
      );

      expect(bus.activeWaitLeases, hasLength(2));
      expect(
        bus.activeWaitLeases.where((l) => l.agentId == 'a2'),
        hasLength(1),
      );
    });
  });

  group('emitListenable', () {
    test('emit 时递增（收件箱 / 最近事件靠它刷新）', () {
      final before = bus.emitListenable.value;
      bus.emitSystem(
        systemDomain: 'test',
        type: 'test.event.ping',
        payload: const {},
        correlationId: 'cid_emit',
      );

      expect(bus.emitListenable.value, greaterThan(before));
    });

    test('listenListenable 不被 emit 拖动', () {
      final before = bus.listenListenable.value;
      bus.emitSystem(
        systemDomain: 'test',
        type: 'test.event.ping',
        payload: const {},
        correlationId: 'cid_emit2',
      );

      expect(bus.listenListenable.value, before);
    });

    test('订阅变更只动 listenListenable', () {
      final emitBefore = bus.emitListenable.value;
      bus.addSubscription(
        agentId: 'a1',
        patterns: const [EventPattern(typeGlob: 'test.event.ping')],
      );

      expect(bus.emitListenable.value, emitBefore);
      expect(bus.listenListenable.value, greaterThan(0));
    });
  });
}

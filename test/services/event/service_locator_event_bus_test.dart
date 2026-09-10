import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shepaw/service_locator.dart';
import 'package:shepaw/services/event/event_bus.dart';

void main() {
  test('setupServiceLocator 暴露的 EventBus 就是全局单例且感知已接线', () {
    setupServiceLocator();

    // 回归：service_locator 曾先 setupEventBus 后 configure，wireEventPerception
    // 取到的是未 configure 的 EventBus.instance（孤儿实例）→ 感知回调绑在它上面，
    // active 唤醒永不触发。
    expect(identical(getIt<EventBus>(), EventBus.instance), isTrue);
    expect(EventBus.instance.perceptionScheduler.onSchedule, isNotNull);
  });

  test('setupServiceLocator 可重复调用且不换实例', () {
    setupServiceLocator();
    final first = getIt<EventBus>();

    setupServiceLocator();

    expect(identical(getIt<EventBus>(), first), isTrue);
  });
}

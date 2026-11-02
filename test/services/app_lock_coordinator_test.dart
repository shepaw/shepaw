import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/services/app_lock_coordinator.dart';
import 'package:shepaw/services/app_lock_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppLockService.key: true,
    });
  });

  late AppLockService lock;
  late bool session;
  late bool onGate;
  late int pushed;
  Completer<void>? screen;

  AppLockCoordinator build() => AppLockCoordinator(
        lock: lock,
        hasSession: () async => session,
        onGate: () => onGate,
        pushLockScreen: () {
          pushed++;
          screen = Completer<void>();
          return screen!.future;
        },
      );

  setUp(() {
    lock = AppLockService(
      authenticate: () async => true,
      deviceSupported: () async => true,
    );
    session = true;
    onGate = false;
    pushed = 0;
    screen = null;
  });

  test('冷启动有登录态且已在主页：弹锁屏', () async {
    final c = build();
    unawaited(c.start());
    await pumpEventQueue();
    expect(lock.locked, isTrue);
    expect(pushed, 1);
  });

  test('冷启动没有登录态：不弹', () async {
    session = false;
    final c = build();
    unawaited(c.start());
    await pumpEventQueue();
    expect(lock.locked, isFalse);
    expect(pushed, 0);
  });

  test('还停在门页时不弹；离开门页进主页后才弹（离线进入也一样）', () async {
    onGate = true;
    final c = build();
    await c.start();
    expect(lock.locked, isTrue);
    expect(pushed, 0);

    // 模拟 unlock_screen 的「离线进入」：没输密码直接进 /home。
    onGate = false;
    unawaited(c.check());
    await pumpEventQueue();
    expect(pushed, 1);
    expect(lock.locked, isTrue);
  });

  test('锁屏还在时重复触发不会叠层', () async {
    final c = build();
    unawaited(c.start());
    await pumpEventQueue();
    for (var i = 0; i < 3; i++) {
      unawaited(c.check());
    }
    await pumpEventQueue();
    expect(pushed, 1);
  });

  test('解锁并关掉锁屏后，下次重新锁才会再弹', () async {
    final c = build();
    unawaited(c.start());
    await pumpEventQueue();
    await lock.unlock();
    screen!.complete();
    await pumpEventQueue();
    expect(pushed, 1);

    lock.debugResumeAfter(const Duration(minutes: 6));
    unawaited(c.check());
    await pumpEventQueue();
    expect(pushed, 2);
  });
}

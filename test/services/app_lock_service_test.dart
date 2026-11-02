import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/app_lock_service.dart';
import 'package:shepaw/utils/platform_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// 多数用例需要「开关是开的」。不写这条的话桌面平台默认是关的。
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppLockService.key: true,
    });
  });

  AppLockService lock({
    bool supported = true,
    bool pass = true,
    Duration? away,
  }) =>
      AppLockService(
        deviceSupported: () async => supported,
        authenticate: () async => pass,
        away: away,
      );

  test('设备没设锁屏方式时一律关掉', () async {
    final service = lock(supported: false);
    await service.load();
    expect(service.supported, isFalse);
    expect(service.enabled, isFalse);
    expect(service.locked, isFalse);
  });

  test('没设过开关时按平台给默认值：手机开，电脑关', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final service = lock();
    await service.load();
    expect(service.enabled, isDesktopPlatform ? isFalse : isTrue);
  });

  test('冷启动有登录态时要先解锁', () async {
    final service = lock();
    await service.load(hasSession: true);
    expect(service.locked, isTrue);
  });

  test('冷启动没有登录态时不上锁', () async {
    final service = lock();
    await service.load(hasSession: false);
    expect(service.enabled, isTrue);
    expect(service.locked, isFalse);
  });

  test('后台不到阈值不重新锁', () async {
    final service = lock(away: const Duration(minutes: 5));
    await service.load();
    await service.unlock();
    expect(service.locked, isFalse);
    service.debugResumeAfter(const Duration(minutes: 4));
    expect(service.locked, isFalse);
  });

  test('后台超过阈值就重新锁', () async {
    final service = lock(away: const Duration(minutes: 5));
    await service.load();
    await service.unlock();
    service.debugResumeAfter(const Duration(minutes: 6));
    expect(service.locked, isTrue);
  });

  test('解锁失败就保持锁着，没有绕过', () async {
    final service = lock(pass: false);
    await service.load();
    expect(await service.unlock(), isFalse);
    expect(service.locked, isTrue);
  });

  test('解锁成功才放行', () async {
    final service = lock(pass: true);
    await service.load();
    expect(await service.unlock(), isTrue);
    expect(service.locked, isFalse);
  });

  test('开启前要先过一次认证，认证不过就不开', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    var pass = false;
    final service = AppLockService(
      deviceSupported: () async => true,
      authenticate: () async => pass,
    );
    await service.load();
    await service.setEnabled(true);
    expect(service.enabled, isFalse);
    pass = true;
    await service.setEnabled(true);
    expect(service.enabled, isTrue);
  });

  test('关掉开关的同时解锁', () async {
    final service = lock();
    await service.load();
    await service.setEnabled(false);
    expect(service.locked, isFalse);
  });
}

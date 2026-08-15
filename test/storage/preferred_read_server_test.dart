import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('preferredReadServer：本机恒为本机', () async {
    final self = await DeviceIdentity.deviceId();
    final server = await StoreService.instance.preferredReadServer(self);
    expect(server, self);
  });

  test('preferredReadServer：未配对他端回退 master', () async {
    const other = 'ffffffffffffffff';
    final master = await StoreService.instance.masterDeviceId();
    final server = await StoreService.instance.preferredReadServer(other);
    expect(server, master);
  });

  test('isDeviceOnline：本机 true，未知指纹 false', () async {
    final self = await DeviceIdentity.deviceId();
    expect(await StoreService.instance.isDeviceOnline(self), isTrue);
    expect(
      await StoreService.instance.isDeviceOnline('eeeeeeeeeeeeeeee'),
      isFalse,
    );
  });

  test('fallbackReadServer：本机且自己是 master 时无需回退', () async {
    final self = await DeviceIdentity.deviceId();
    expect(await StoreService.instance.masterDeviceId(), self);
    expect(await StoreService.instance.fallbackReadServer(self), isNull);
  });

  test('fallbackReadServer：他端走 preferredReadServer', () async {
    const other = 'ffffffffffffffff';
    final server = await StoreService.instance.fallbackReadServer(other);
    expect(server, await StoreService.instance.preferredReadServer(other));
  });
}

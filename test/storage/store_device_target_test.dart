import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_device_target.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('StoreDeviceResolver：URI device 等于本机 → 本机读取', () async {
    final self = await DeviceIdentity.deviceId();
    final target = await StoreDeviceResolver.resolve(self);
    expect(target.isLocal, isTrue);
    expect(target.deviceId, self);
    expect(target.peerId, isNull);
  });

  test('StoreDeviceResolver：其它 device id → 对该设备远端读取', () async {
    const other = 'ffffffffffffffff';
    final target = await StoreDeviceResolver.resolve(other);
    expect(target.isLocal, isFalse);
    expect(target.deviceId, other);
  });
}

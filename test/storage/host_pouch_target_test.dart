import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/host_pouch_target.dart';

void main() {
  test('手机和电脑都打开主机的袋子', () {
    for (final self in ['phone-device', 'mac-app']) {
      final target = HostPouchTarget.decide(
        selfId: self,
        hostFingerprint: 'host-device',
        hostPeerId: 'host-peer',
      );
      expect(target.isRemote, isTrue, reason: self);
      expect(target.deviceId, 'host-device');
      expect(target.peerId, 'host-peer');
    }
  });

  test('本机指纹就是主机时读本机目录', () {
    final target = HostPouchTarget.decide(
      selfId: 'host-device',
      hostFingerprint: 'HOST-DEVICE',
      hostPeerId: 'host-peer',
    );
    expect(target.isRemote, isFalse);
    expect(target.deviceId, 'host-device');
  });

  test('还没登录时读本机目录', () {
    final target = HostPouchTarget.decide(
      selfId: 'phone-device',
      hostFingerprint: null,
      hostPeerId: null,
    );
    expect(target.isRemote, isFalse);
    expect(target.deviceId, 'phone-device');
  });
}

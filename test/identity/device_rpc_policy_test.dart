import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/utils/device_rpc_policy.dart';

void main() {
  group('DeviceRpcPolicy', () {
    test('App cannot invoke cli.exec', () {
      expect(DeviceRpcPolicy.callerMayInvoke('cli.exec', DeviceRole.app), isFalse);
      expect(DeviceRpcPolicy.callerMayInvoke('cli.exec', DeviceRole.primary), isTrue);
      expect(DeviceRpcPolicy.callerMayInvoke('cli.exec', DeviceRole.backup), isTrue);
    });

    test('App may invoke read-only RPC methods', () {
      expect(DeviceRpcPolicy.callerMayInvoke('messages.fetch', DeviceRole.app), isTrue);
      expect(DeviceRpcPolicy.callerMayInvoke('sync.status', DeviceRole.app), isTrue);
    });

    test('App device rejects inbound cli.exec', () {
      expect(DeviceRpcPolicy.receiverMayExecute('cli.exec', DeviceRole.app), isFalse);
      expect(DeviceRpcPolicy.receiverMayExecute('cli.exec', DeviceRole.primary), isTrue);
    });
  });
}

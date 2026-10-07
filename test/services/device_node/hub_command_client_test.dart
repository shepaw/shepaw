import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/device_node/hub_command_client.dart';

void main() {
  test('unreachable hub stays read only after arguments validate', () {
    final result = HubCommandClient().call('pouch.read', {
      'uri': 'pouch://files/0123456789abcdef/a.md',
    });
    expect(result.ok, isFalse);
    expect(result.readOnly, isTrue);
    expect(result.code, 'device_offline');
  });

  test('invalid arguments fail before reachability', () {
    final result = HubCommandClient(reachable: true).call('os.file.read', {});
    expect(result.code, 'invalid_args');
    expect(result.readOnly, isFalse);
  });
}

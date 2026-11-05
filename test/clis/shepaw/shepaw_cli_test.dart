import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/shepaw_cli.dart';

void main() {
  test('call token is redacted from CLI logs', () {
    final redacted = ShepawCLI.redactSensitiveFlags({
      'reason': 'user_requested',
      'call_token': 'tok-secret',
      'token': 'other-secret',
    });
    expect(redacted['call_token'], '<redacted>');
    expect(redacted['token'], '<redacted>');
    expect(redacted['reason'], 'user_requested');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/inbox_subscribe_service.dart';

void main() {
  test('wsUrlFromChannelBase builds subscribe URL', () {
    expect(
      InboxSubscribeService.wsUrlFromChannelBase(
        'https://channel.example.com',
        'abcd1234abcd1234',
      ),
      'wss://channel.example.com/api/v1/inbox/subscribe?caller_fp=abcd1234abcd1234',
    );
  });
}

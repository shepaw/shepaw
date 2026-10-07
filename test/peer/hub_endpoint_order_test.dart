import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/hub_endpoint_order.dart';

void main() {
  test('custom addresses are tried before lan and channel', () {
    expect(
      hubEndpointOrder(
        custom: ['wss://hub.example/peer/ws'],
        lan: 'ws://192.168.1.8:18793/peer/ws',
        channel: 'wss://channel.example/peer/ws',
      ),
      [
        'wss://hub.example/peer/ws',
        'ws://192.168.1.8:18793/peer/ws',
        'wss://channel.example/peer/ws',
      ],
    );
  });

  test('channel can be turned off', () {
    expect(
      hubEndpointOrder(
        lan: 'ws://127.0.0.1:18793/peer/ws',
        channel: 'wss://channel.example/peer/ws',
        channelEnabled: false,
      ),
      ['ws://127.0.0.1:18793/peer/ws'],
    );
  });
}

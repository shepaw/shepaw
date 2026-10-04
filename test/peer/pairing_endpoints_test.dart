import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/pairing_endpoints.dart';

void main() {
  test('本机 CLI 的配对结果保留回环地址', () {
    final kept = pairingEndpointsForPeer(
      peerFingerprint: 'C1B74877DEBB2FD6',
      localCliFingerprint: 'c1b74877debb2fd6',
      loopbackEndpoint: 'ws://127.0.0.1:18794/peer/ws',
      offeredLocal: 'ws://192.168.41.3:18794/peer/ws',
      offeredChannel: 'wss://channel.example/peer/ws',
    );

    expect(kept.localEndpoint, 'ws://127.0.0.1:18794/peer/ws');
    expect(kept.channelEndpoint, isNull);
  });

  test('别的设备仍用二维码里的地址', () {
    final kept = pairingEndpointsForPeer(
      peerFingerprint: 'aaaaaaaaaaaaaaaa',
      localCliFingerprint: 'c1b74877debb2fd6',
      loopbackEndpoint: 'ws://127.0.0.1:18794/peer/ws',
      offeredLocal: 'ws://192.168.1.9/peer/ws',
      offeredChannel: 'wss://channel.example/peer/ws',
    );

    expect(kept.localEndpoint, 'ws://192.168.1.9/peer/ws');
    expect(kept.channelEndpoint, 'wss://channel.example/peer/ws');
  });
}

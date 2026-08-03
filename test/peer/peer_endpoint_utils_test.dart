import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_endpoint_utils.dart';

void main() {
  group('isOwnLocalEndpoint', () {
    test('same host and port is own', () {
      expect(
        isOwnLocalEndpoint(
          'ws://192.168.31.16:18792/peer/ws',
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isTrue,
      );
    });

    test('same host different port (Nexuspouch) is not own', () {
      expect(
        isOwnLocalEndpoint(
          'ws://192.168.31.16:19000/peer/ws',
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isFalse,
      );
    });

    test('loopback to own listen port is own', () {
      expect(
        isOwnLocalEndpoint(
          'ws://127.0.0.1:18792/peer/ws',
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isTrue,
      );
    });

    test('loopback to other port is not own', () {
      expect(
        isOwnLocalEndpoint(
          'ws://127.0.0.1:19000/peer/ws',
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isFalse,
      );
    });

    test('null own listener is never own', () {
      expect(
        isOwnLocalEndpoint(
          'ws://192.168.31.16:18792/peer/ws',
          ownHost: null,
          ownPort: null,
        ),
        isFalse,
      );
    });
  });

  group('learnLocalEndpointFromRemoteAddress', () {
    test('preserves existing Nexuspouch port when refreshing host', () {
      expect(
        learnLocalEndpointFromRemoteAddress(
          remoteAddress: '192.168.31.20',
          existingLocalEndpoint: 'ws://192.168.31.16:19000/peer/ws',
          defaultPort: 18792,
          ownHost: '192.168.31.20',
          ownPort: 18792,
        ),
        'ws://192.168.31.20:19000/peer/ws',
      );
    });

    test('rejects candidate that equals own PeerLocalServer', () {
      expect(
        learnLocalEndpointFromRemoteAddress(
          remoteAddress: '192.168.31.16',
          existingLocalEndpoint: null,
          defaultPort: 18792,
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isNull,
      );
    });

    test('does not overwrite Nexuspouch port with default on same-machine inbound',
        () {
      // App at .16:18792; Nexuspouch on same host :19000 connects in.
      // remoteAddress is App's LAN IP; must keep port 19000.
      expect(
        learnLocalEndpointFromRemoteAddress(
          remoteAddress: '192.168.31.16',
          existingLocalEndpoint: 'ws://192.168.31.16:19000/peer/ws',
          defaultPort: 18792,
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        isNull, // unchanged
      );
    });

    test('sets default port when no existing endpoint and not own', () {
      expect(
        learnLocalEndpointFromRemoteAddress(
          remoteAddress: '192.168.31.99',
          existingLocalEndpoint: null,
          defaultPort: 18792,
          ownHost: '192.168.31.16',
          ownPort: 18792,
        ),
        'ws://192.168.31.99:18792/peer/ws',
      );
    });
  });
}

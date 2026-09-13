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

  group('peerEndpointPort', () {
    test('reads explicit port', () {
      expect(peerEndpointPort('ws://192.168.31.21:18794/peer/ws'), 18794);
    });

    test('defaults ws without port to 80', () {
      expect(peerEndpointPort('ws://192.168.31.21/peer/ws'), 80);
    });

    test('returns null for empty', () {
      expect(peerEndpointPort(null), isNull);
      expect(peerEndpointPort(''), isNull);
    });
  });

  group('lanPeerScanEndpoints', () {
    test('scans Hub default range and skips already-tried ports', () {
      expect(
        lanPeerScanEndpoints(
          lanHost: '192.168.31.21',
          skipPorts: {kAppPeerDefaultPort, 18794},
        ),
        [
          'ws://192.168.31.21:18793/peer/ws',
          'ws://192.168.31.21:18795/peer/ws',
          'ws://192.168.31.21:18796/peer/ws',
          'ws://192.168.31.21:18797/peer/ws',
          'ws://192.168.31.21:18798/peer/ws',
          'ws://192.168.31.21:18799/peer/ws',
        ],
      );
    });

    test('brackets IPv6 hosts', () {
      expect(
        lanPeerScanEndpoints(
          lanHost: 'fe80::1',
          startPort: 18793,
          endPort: 18793,
        ),
        ['ws://[fe80::1]:18793/peer/ws'],
      );
    });

    test('returns empty when host missing or range inverted', () {
      expect(lanPeerScanEndpoints(lanHost: ''), isEmpty);
      expect(
        lanPeerScanEndpoints(
          lanHost: '192.168.31.21',
          startPort: 18799,
          endPort: 18793,
        ),
        isEmpty,
      );
    });
  });

  group('canReachLanPeer', () {
    test('same /24 is reachable', () {
      expect(
        canReachLanPeer(
          peerLanHost: '192.168.31.21',
          localIpv4s: {'192.168.31.50'},
        ),
        isTrue,
      );
    });

    test('exact same address is reachable', () {
      expect(
        canReachLanPeer(
          peerLanHost: '192.168.31.21',
          localIpv4s: {'192.168.31.21'},
        ),
        isTrue,
      );
    });

    test('cellular or other Wi-Fi is not on home LAN', () {
      expect(
        canReachLanPeer(
          peerLanHost: '192.168.31.21',
          localIpv4s: {'10.12.34.56', '100.64.1.8'},
        ),
        isFalse,
      );
      expect(
        canReachLanPeer(
          peerLanHost: '192.168.31.21',
          localIpv4s: {'192.168.1.8'},
        ),
        isFalse,
      );
    });

    test('missing peer or no local IPv4 is not reachable', () {
      expect(
        canReachLanPeer(peerLanHost: null, localIpv4s: {'192.168.31.50'}),
        isFalse,
      );
      expect(
        canReachLanPeer(peerLanHost: '192.168.31.21', localIpv4s: const {}),
        isFalse,
      );
      expect(
        canReachLanPeer(
          peerLanHost: 'hub.local',
          localIpv4s: {'192.168.31.50'},
        ),
        isFalse,
      );
    });
  });
}

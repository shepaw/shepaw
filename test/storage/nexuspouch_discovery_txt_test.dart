import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/nexuspouch_discovery_service.dart';

void main() {
  test('service type constant', () {
    expect(NexuspouchDiscoveryService.serviceType, '_nexuspouch._tcp.local');
  });

  test('discovered peer short fingerprint', () {
    const peer = DiscoveredNexuspouch(
      name: 'nas',
      fingerprint: '0123456789abcdef',
      host: '192.168.1.8',
      port: 8787,
      endpoint: 'ws://192.168.1.8:8787/peer/ws',
      path: '/peer/ws',
    );
    expect(peer.shortFp, '01234567…');
  });
}

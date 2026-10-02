import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/store_protocol.dart';

void main() {
  const hub = 'aaaaaaaaaaaaaaaa';
  const phone = 'bbbbbbbbbbbbbbbb';

  test('Hub 盖章的请求者用于 ACL，直连自报无效', () {
    final relayed = callerForStoreFrame(
      connectedPeerId: 'hub-peer',
      connectedFingerprint: hub,
      connectedTrust: TrustLevel.owner,
      fromDevice: phone,
      fromPeerId: 'phone-peer',
    );
    expect(relayed.deviceId, phone);
    expect(relayed.trustLevel, TrustLevel.friend);

    final known = callerForStoreFrame(
      connectedPeerId: 'hub-peer',
      connectedFingerprint: hub,
      connectedTrust: TrustLevel.owner,
      fromDevice: phone,
      fromPeerId: 'phone-peer',
      knownOrigin: const KnownRelayPeer(
        id: 'phone-peer',
        fingerprint: phone,
        trustLevel: TrustLevel.owner,
      ),
    );
    expect(known.deviceId, phone);
    expect(known.trustLevel, TrustLevel.owner);

    final forgedOnDirect = callerForStoreFrame(
      connectedPeerId: 'friend-peer',
      connectedFingerprint: hub,
      connectedTrust: TrustLevel.friend,
      fromDevice: phone,
      fromPeerId: 'phone-peer',
    );
    expect(forgedOnDirect.deviceId, hub);
    expect(forgedOnDirect.trustLevel, TrustLevel.friend);

    final mismatch = callerForStoreFrame(
      connectedPeerId: 'hub-peer',
      connectedFingerprint: hub,
      connectedTrust: TrustLevel.owner,
      fromDevice: phone,
      fromPeerId: 'phone-peer',
      knownOrigin: const KnownRelayPeer(
        id: 'phone-peer',
        fingerprint: 'cccccccccccccccc',
        trustLevel: TrustLevel.owner,
      ),
    );
    expect(mismatch.deviceId, hub);
  });
}

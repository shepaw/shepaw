import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

void main() {
  group('selectDirtySessions', () {
    final t0 = DateTime.utc(2026, 7, 12, 12, 0);
    final sessions = [
      PeerRemoteSession(sessionId: 'a', updatedAt: t0.subtract(const Duration(hours: 2))),
      PeerRemoteSession(sessionId: 'b', updatedAt: t0.subtract(const Duration(minutes: 1))),
      PeerRemoteSession(sessionId: 'c', updatedAt: t0.add(const Duration(minutes: 5))),
      PeerRemoteSession(sessionId: 'd'), // no updatedAt
    ];

    test('null lastSyncAt marks every session dirty', () {
      final dirty = selectDirtySessions(sessions, lastSyncAt: null);
      expect(dirty.map((s) => s.sessionId).toList(), ['a', 'b', 'c', 'd']);
    });

    test('filters by lastSyncAt minus overlap', () {
      // since = t0 - 2min → b (t0-1min), c (t0+5), d (null) are dirty; a is not
      final dirty = selectDirtySessions(sessions, lastSyncAt: t0);
      expect(dirty.map((s) => s.sessionId).toList(), ['b', 'c', 'd']);
    });

    test('includes session exactly at since boundary', () {
      final since = t0.subtract(kPeerHistorySyncOverlap);
      final boundary = [
        PeerRemoteSession(sessionId: 'edge', updatedAt: since),
        PeerRemoteSession(
          sessionId: 'before',
          updatedAt: since.subtract(const Duration(milliseconds: 1)),
        ),
      ];
      final dirty = selectDirtySessions(boundary, lastSyncAt: t0);
      expect(dirty.map((s) => s.sessionId).toList(), ['edge']);
    });

    test('missing updatedAt is always dirty when watermark exists', () {
      final dirty = selectDirtySessions(
        [PeerRemoteSession(sessionId: 'no-ts')],
        lastSyncAt: t0,
      );
      expect(dirty.single.sessionId, 'no-ts');
    });

    test('prioritizeSessionId moves matching session to front', () {
      final dirty = selectDirtySessions(
        sessions,
        lastSyncAt: t0,
        prioritizeSessionId: 'c',
      );
      expect(dirty.map((s) => s.sessionId).toList(), ['c', 'b', 'd']);
    });

    test('prioritizeSessionId is a no-op when session is not dirty', () {
      final dirty = selectDirtySessions(
        sessions,
        lastSyncAt: t0,
        prioritizeSessionId: 'a',
      );
      expect(dirty.map((s) => s.sessionId).toList(), ['b', 'c', 'd']);
    });
  });

  group('peerHistoryLastSyncPrefsKey', () {
    test('is stable per agent id', () {
      expect(
        peerHistoryLastSyncPrefsKey('peeragent_x_y'),
        'peer_history_last_sync_peeragent_x_y',
      );
    });
  });
}

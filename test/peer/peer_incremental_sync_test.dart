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

  group('assignPeerHistoryTimestamps', () {
    final end = DateTime.utc(2026, 7, 12, 12, 0);

    test('uses remote createdAt when present', () {
      final t1 = DateTime.utc(2026, 7, 1, 10);
      final t2 = DateTime.utc(2026, 7, 1, 10, 1);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a', createdAt: t1),
        PeerHistoryMessage(role: 'agent', content: 'b', createdAt: t2),
      ];
      expect(
        assignPeerHistoryTimestamps(history, sessionUpdatedAt: end),
        [t1, t2],
      );
    });

    test('anchors to sessionUpdatedAt when remote has no stamps', () {
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a'),
        PeerHistoryMessage(role: 'agent', content: 'b'),
        PeerHistoryMessage(role: 'user', content: 'c'),
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        sessionUpdatedAt: end,
        existingById: {
          'peerhist_x': DateTime.utc(2026, 7, 12, 11, 59), // ignored: no remote stamps
        },
        idFor: (m, i) => 'peerhist_$i',
      );
      expect(times, [
        end.subtract(const Duration(minutes: 2)),
        end.subtract(const Duration(minutes: 1)),
        end,
      ]);
    });

    test('preserves existing local time for unstamped gaps when any remote stamp exists', () {
      final remote = DateTime.utc(2026, 7, 1, 10);
      final local = DateTime.utc(2026, 7, 1, 10, 0, 30);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a', createdAt: remote),
        PeerHistoryMessage(role: 'agent', content: 'b'), // no stamp
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        existingById: {'peerhist_1': local},
        sessionUpdatedAt: end,
        idFor: (m, i) => 'peerhist_$i',
      );
      expect(times[0], remote);
      expect(times[1], local);
    });

    test('enforces non-decreasing order', () {
      final earlier = DateTime.utc(2026, 7, 1, 10);
      final later = DateTime.utc(2026, 7, 1, 11);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a', createdAt: later),
        PeerHistoryMessage(role: 'agent', content: 'b', createdAt: earlier),
      ];
      final times = assignPeerHistoryTimestamps(history, sessionUpdatedAt: end);
      expect(times[0], later);
      expect(times[1], later.add(const Duration(seconds: 1)));
    });
  });
}

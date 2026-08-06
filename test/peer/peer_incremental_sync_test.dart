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

  group('collectLocalBoundRemoteSessionIds', () {
    test('includes psess channels and legacy live channels', () {
      final remote = {'sess-a', 'dm_user_agent_123'};
      final bound = collectLocalBoundRemoteSessionIds(
        [
          'psess_sess-a',
          'dm_user_agent_123',
          'dm_user_agent_999', // unknown locally — not bound
        ],
        remote,
      );
      expect(bound, {'sess-a', 'dm_user_agent_123'});
    });
  });

  group('resolveLocalPeerChannelId', () {
    test('prefers legacy live channel over psess shell', () {
      expect(
        resolveLocalPeerChannelId(
          'dm_user_agent_123',
          psessExists: true,
          legacyExists: true,
        ),
        'dm_user_agent_123',
      );
    });

    test('uses psess when only psess exists', () {
      expect(
        resolveLocalPeerChannelId(
          'sess-a',
          psessExists: true,
          legacyExists: false,
        ),
        'psess_sess-a',
      );
    });

    test('defaults to psess for brand-new remote session', () {
      expect(
        resolveLocalPeerChannelId(
          'sess-new',
          psessExists: false,
          legacyExists: false,
        ),
        'psess_sess-new',
      );
    });
  });

  group('peerRemoteSessionIdForLocalChannel', () {
    test('maps psess and legacy channels', () {
      final known = {'dm_user_agent_123', 'sess-b'};
      expect(
        peerRemoteSessionIdForLocalChannel(
          'psess_sess-b',
          knownRemoteSessionIds: known,
        ),
        'sess-b',
      );
      expect(
        peerRemoteSessionIdForLocalChannel(
          'dm_user_agent_123',
          knownRemoteSessionIds: known,
        ),
        'dm_user_agent_123',
      );
      expect(
        peerRemoteSessionIdForLocalChannel(
          'dm_user_agent_other',
          knownRemoteSessionIds: known,
        ),
        isNull,
      );
    });
  });

  group('localChannelBindsRemoteSession', () {
    test('matches psess and legacy ids', () {
      expect(
        localChannelBindsRemoteSession('psess_abc', 'abc'),
        isTrue,
      );
      expect(
        localChannelBindsRemoteSession('dm_user_agent_1', 'dm_user_agent_1'),
        isTrue,
      );
      expect(
        localChannelBindsRemoteSession('psess_abc', 'xyz'),
        isFalse,
      );
    });
  });

  group('PeerHistoryMessage.fromJson progress fields', () {
    test('parses the reconstructed progress section', () {
      final m = PeerHistoryMessage.fromJson({
        'role': 'agent',
        'content': 'Done.',
        'progress_content': 'Thinking…\n[completed] Bash\n```\nls\n```',
        'progress_title': 'Bash',
        'progress_auto_collapse': false,
      })!;
      expect(m.progressContent, contains('[completed] Bash'));
      expect(m.progressTitle, 'Bash');
      expect(m.progressAutoCollapse, isFalse);
    });

    test('treats missing/empty progress as absent (backward compatible)', () {
      final legacy = PeerHistoryMessage.fromJson({
        'role': 'agent',
        'content': 'plain',
      })!;
      expect(legacy.progressContent, isNull);
      expect(legacy.progressTitle, isNull);
      expect(legacy.progressAutoCollapse, isNull);

      final empty = PeerHistoryMessage.fromJson({
        'role': 'agent',
        'content': 'plain',
        'progress_content': '',
      })!;
      expect(empty.progressContent, isNull);
    });
  });

  group('preservedReadStateForHistorySync', () {
    test('returns 0 for brand-new remote rows', () {
      expect(
        preservedReadStateForHistorySync(
          remote: PeerHistoryMessage(role: 'agent', content: 'hi'),
        ),
        0,
      );
    });

    test('preserves read bit when role and content are unchanged', () {
      expect(
        preservedReadStateForHistorySync(
          remote: PeerHistoryMessage(role: 'agent', content: 'hi'),
          existingRow: {
            'sender_type': 'agent',
            'content': 'hi',
            'is_read': 1,
          },
        ),
        1,
      );
    });

    test('resets to unread when content changed on remote', () {
      expect(
        preservedReadStateForHistorySync(
          remote: PeerHistoryMessage(role: 'agent', content: 'updated'),
          existingRow: {
            'sender_type': 'agent',
            'content': 'old',
            'is_read': 1,
          },
        ),
        0,
      );
    });
  });

  group('peerHistoryMessageMetadata', () {
    test('maps progress into the live stream metadata shape', () {
      final meta = peerHistoryMessageMetadata(
        PeerHistoryMessage(
          role: 'agent',
          content: 'answer',
          progressContent: 'thinking',
          progressTitle: 'Thinking',
        ),
      )!;
      expect(meta['progress_content'], 'thinking');
      expect(meta['collapsible'], isTrue);
      expect(meta['collapsible_title'], 'Thinking');
      expect(meta['auto_collapse'], isTrue);
    });

    test('falls back to Details title and null when no progress', () {
      final titled = peerHistoryMessageMetadata(
        PeerHistoryMessage(role: 'agent', content: 'a', progressContent: 'p'),
      )!;
      expect(titled['collapsible_title'], 'Details');
      expect(
        peerHistoryMessageMetadata(
          PeerHistoryMessage(role: 'agent', content: 'a'),
        ),
        isNull,
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

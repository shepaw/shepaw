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

  group('peerHistoryDisplayFields', () {
    test('marks pure Scope Card as ui_hidden', () {
      final m = PeerHistoryMessage(
        role: 'user',
        content: '## 当前储物袋作用域\n- schema: v1 · mode: `acp`',
      );
      final out = peerHistoryDisplayFields(m);
      expect(out.metadata?['ui_hidden'], isTrue);
      expect(out.metadata?['history_exclude'], isTrue);
    });

    test('strips Scope Card prefix for bundled user text', () {
      final m = PeerHistoryMessage(
        role: 'user',
        content: '## 当前储物袋作用域\n- device: `x`\n\n排查 bug',
      );
      final out = peerHistoryDisplayFields(m);
      expect(out.content, '排查 bug');
      expect(out.metadata?['wire_content'], m.content);
      expect(out.metadata?['ui_hidden'], isNull);
    });

    test('keeps markdown newlines in the synced answer', () {
      final m = PeerHistoryMessage(
        role: 'agent',
        content: '上一行\n\n## 标题\n\n正文',
      );
      final out = peerHistoryDisplayFields(m);
      expect(out.content, '上一行\n\n## 标题\n\n正文');
      expect(out.metadata?['wire_content'], isNull);
    });

    test('honors Hub protocol metadata without content heuristics', () {
      final m = PeerHistoryMessage.fromJson({
        'role': 'user',
        'content': 'plain user text',
        'metadata': {
          'ui_hidden': true,
          'history_exclude': true,
          'kind': 'scope_card_stable',
        },
      })!;
      final out = peerHistoryDisplayFields(
        m,
        baseMetadata: peerHistoryMessageMetadata(m),
      );
      expect(out.metadata?['ui_hidden'], isTrue);
      expect(out.metadata?['history_exclude'], isTrue);
      expect(out.metadata?['kind'], 'scope_card_stable');
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

    test('keeps read bit when stored text was only whitespace-collapsed', () {
      expect(
        preservedReadStateForHistorySync(
          remote: PeerHistoryMessage(
            role: 'agent',
            content: '上一行\n\n## 标题',
          ),
          existingRow: {
            'sender_type': 'agent',
            'content': '上一行 ## 标题',
            'is_read': 1,
            'metadata': '{"wire_content":"上一行\\n\\n## 标题"}',
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

    test('reuses existing local time over the session anchor (idempotent resync)', () {
      final local0 = DateTime.utc(2026, 7, 1, 10);
      final local1 = DateTime.utc(2026, 7, 1, 10, 0, 30);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a'),
        PeerHistoryMessage(role: 'agent', content: 'b'),
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        existingById: {'peerhist_0': local0, 'peerhist_1': local1},
        sessionUpdatedAt: end,
        latestMirroredLocalAt: local1,
        idFor: (m, i) => 'peerhist_$i',
      );
      expect(times, [local0, local1]);
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

    test('合成批不早于已镜像的本地消息（会话锚过期时整体前移）', () {
      final remoteEnd = DateTime.utc(2026, 7, 12, 11, 55);
      final mirroredLatest = DateTime.utc(2026, 7, 12, 12, 0);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a'),
        PeerHistoryMessage(role: 'agent', content: 'b'),
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        sessionUpdatedAt: remoteEnd,
        latestMirroredLocalAt: mirroredLatest,
      );
      // 批内间隔保持 1 分钟，末条落在本地最新消息之后。
      expect(times.last, mirroredLatest.add(const Duration(seconds: 1)));
      expect(
        times.last.difference(times.first),
        const Duration(minutes: 1),
      );
    });

    test('本地不比整批新时不平移（幂等）', () {
      final remoteEnd = DateTime.utc(2026, 7, 12, 12, 0);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'a'),
        PeerHistoryMessage(role: 'agent', content: 'b'),
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        sessionUpdatedAt: remoteEnd,
        latestMirroredLocalAt: remoteEnd.subtract(const Duration(minutes: 5)),
      );
      expect(times.last, remoteEnd);
    });

    test('权威远端时间不因本地下界而平移（回复不会被顶到新消息之后）', () {
      // 上一回合已镜像；用户又发了一条，远端 transcript 还没有它。
      final q1 = DateTime.utc(2026, 7, 12, 11, 50);
      final a1 = DateTime.utc(2026, 7, 12, 11, 50, 1);
      final justSentLocally = DateTime.utc(2026, 7, 12, 12, 0);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'Q1', createdAt: q1),
        PeerHistoryMessage(role: 'agent', content: 'A1', createdAt: a1),
      ];
      final times = assignPeerHistoryTimestamps(
        history,
        existingById: {'peerhist_0': q1, 'peerhist_1': a1},
        latestMirroredLocalAt: a1,
        idFor: (m, i) => 'peerhist_$i',
      );
      expect(times, [q1, a1]);
      expect(times.last.isBefore(justSentLocally), isTrue);
    });

    test('重复同步不会把整段 transcript 往后推（幂等）', () {
      final q1 = DateTime.utc(2026, 7, 12, 11, 50);
      final a1 = DateTime.utc(2026, 7, 12, 11, 50, 1);
      final history = [
        PeerHistoryMessage(role: 'user', content: 'Q1', createdAt: q1),
        PeerHistoryMessage(role: 'agent', content: 'A1', createdAt: a1),
      ];
      var existing = {'peerhist_0': q1, 'peerhist_1': a1};
      // 本地存在一条更新的实时行（远端尚未收录）。
      var mirroredLatest = a1;
      for (var round = 0; round < 4; round++) {
        final times = assignPeerHistoryTimestamps(
          history,
          existingById: existing,
          latestMirroredLocalAt: mirroredLatest,
          idFor: (m, i) => 'peerhist_$i',
        );
        expect(times, [q1, a1], reason: 'round $round drifted');
        existing = {'peerhist_0': times[0], 'peerhist_1': times[1]};
        mirroredLatest = times.last;
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/peer/services/peer_inflight_turn.dart';

void main() {
  const channelId = 'psess_s';

  Map<String, dynamic> row(String role, String content, DateTime at) => {
        'sender_type': role,
        'content': content,
        'created_at': at.toIso8601String(),
      };

  PeerHistoryMessage message(String id, String content,
      {String role = 'user'}) {
    return PeerHistoryMessage(
      role: role,
      content: content,
      messageId: id,
      createdAt: DateTime.utc(2026, 1, 1),
    );
  }

  group('peer history cursor sync', () {
    test('cold-start pages use absolute positions for fallback ids', () {
      final bare = PeerHistoryMessage(role: 'user', content: 'x');
      expect(
          peerHistoryMessageId(bare, channelId, 0), 'peerhist_${channelId}_0');
      expect(
        peerHistoryMessageId(bare, channelId, 99),
        'peerhist_${channelId}_99',
      );
      expect(
        peerHistoryMessageId(bare, channelId, 99),
        isNot(peerHistoryMessageId(bare, channelId, 0)),
      );

      // 250 messages, limit 100: pages start at 0, 99, 198 and overlap by one.
      const pages = <({int from, int length})>[
        (from: 0, length: 100),
        (from: 99, length: 100),
        (from: 198, length: 52),
      ];
      final covered = <int>{};
      for (final page in pages) {
        for (var i = 0; i < page.length; i++) {
          final absolute = page.from + i;
          expect(
            peerHistoryMessageId(bare, channelId, absolute),
            'peerhist_${channelId}_$absolute',
          );
          covered.add(absolute);
        }
      }
      expect(covered, {for (var i = 0; i < 250; i++) i});
      expect(
        peerHistoryFetchMode(storedCursor: null, hasLocalMirroredRows: false),
        PeerHistoryFetchMode.cold,
      );
    });

    test('an incremental slice writes the changed tail and new rows only', () {
      final at = DateTime.utc(2026, 1, 1);
      final existing = <String, Map<String, dynamic>>{
        for (var i = 0; i < 300; i++) 'peerhist_m$i': row('user', 'old-$i', at),
      };
      final history = [
        message('m299', 'new-tail'),
        message('m300', 'added-1'),
        message('m301', 'added-2', role: 'agent'),
      ];
      final indexes = peerHistorySliceWriteIndexes(
        history: history,
        from: 299,
        channelId: channelId,
        existingById: existing,
        createdAts: [at, at, at],
      );
      expect(indexes, [0, 1, 2]);
      final written = [
        for (final i in indexes) 'peerhist_${history[i].messageId}',
      ];
      expect(written, ['peerhist_m299', 'peerhist_m300', 'peerhist_m301']);
      for (var i = 0; i < 299; i++) {
        expect(written, isNot(contains('peerhist_m$i')));
      }
    });

    test('an unchanged tail is not rewritten', () {
      final at = DateTime.utc(2026, 1, 1);
      final indexes = peerHistorySliceWriteIndexes(
        history: [message('m299', 'same')],
        from: 299,
        channelId: channelId,
        existingById: {'peerhist_m299': row('user', 'same', at)},
        createdAts: [at],
      );
      expect(indexes, isEmpty);
    });

    test('deleting one synced row is not undone by a later slice', () {
      final at = DateTime.utc(2026, 1, 1);
      final existing = <String, Map<String, dynamic>>{
        for (var i = 0; i < 300; i++)
          if (i != 10) 'peerhist_m$i': row('user', 'old-$i', at),
      };
      final indexes = peerHistorySliceWriteIndexes(
        history: [message('m299', 'old-299')],
        from: 299,
        channelId: channelId,
        existingById: existing,
        createdAts: [at],
      );
      expect(indexes, isEmpty);
      expect(existing.containsKey('peerhist_m10'), isFalse);
    });

    test('incremental delete drops a local prompt and keeps peerhist rows', () {
      final slice = [
        message('m10', '问'),
        message('m11', '答', role: 'agent'),
      ];
      final sliceIds = {
        for (final item in slice) 'peerhist_${item.messageId}',
      };
      final localPeerhist = [for (var i = 0; i < 12; i++) 'peerhist_m$i'];
      final toDelete = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: [
          for (final id in localPeerhist)
            PeerHistorySyncLocalRow(
              id: id,
              senderType: 'user',
              content: 'kept',
            ),
          const PeerHistorySyncLocalRow(
            id: 'local-question',
            senderType: 'user',
            content: '问',
          ),
        ],
        remoteIds: peerHistorySliceDeleteRemoteIds(
          sliceIds: sliceIds,
          localPeerhistIds: localPeerhist,
        ),
        remoteRoleContentKeys: {
          peerHistoryRoleContentKey('user', '问'),
          peerHistoryRoleContentKey('agent', '答'),
        },
        preserveIds: const {},
        remoteAgentContents: const ['答'],
        remoteTranscript: const [
          PeerHistoryRemoteEntry(role: 'user', content: '问'),
          PeerHistoryRemoteEntry(role: 'agent', content: '答'),
        ],
      );
      expect(toDelete, {'local-question'});
    });

    test('reset reapplies the full transcript; an empty reset drops the cursor',
        () {
      expect(
        peerHistoryApplyKind(
          supportsCursor: true,
          mode: PeerHistoryFetchMode.incremental,
          reset: true,
          messagesEmpty: false,
        ),
        PeerHistoryApplyKind.full,
      );
      expect(
        peerHistoryApplyKind(
          supportsCursor: true,
          mode: PeerHistoryFetchMode.incremental,
          reset: true,
          messagesEmpty: true,
        ),
        PeerHistoryApplyKind.keepLocal,
      );
      expect(
        peerHistoryCursorAction(
          supportsCursor: true,
          reset: true,
          messagesEmpty: true,
          cursor: 'v1.0.abc',
        ),
        PeerHistoryCursorAction.delete,
      );
      expect(
        peerHistoryCursorAction(
          supportsCursor: true,
          reset: true,
          messagesEmpty: false,
          cursor: 'v1.4.abc',
        ),
        PeerHistoryCursorAction.store,
      );
    });

    test('an old hub response is a full compare and does not store a cursor',
        () {
      expect(
        peerHistoryApplyKind(
          supportsCursor: false,
          mode: PeerHistoryFetchMode.cold,
          reset: false,
          messagesEmpty: false,
        ),
        PeerHistoryApplyKind.full,
      );
      expect(
        peerHistoryCursorAction(
          supportsCursor: false,
          reset: false,
          messagesEmpty: false,
          cursor: null,
        ),
        PeerHistoryCursorAction.skip,
      );
    });

    test('message_count skips a quiet session and syncs an unstamped growth',
        () {
      final quiet = PeerRemoteSession(
        sessionId: 'quiet',
        updatedAt: DateTime.utc(2026, 1, 1),
        messageCount: 10,
      );
      final grew = PeerRemoteSession(sessionId: 'grew', messageCount: 11);
      final skipped = assembleSessionsToSync(
        sessions: [quiet],
        lastSyncAt: DateTime.utc(2026, 8, 1),
        syncedUnstampedIds: const {},
        emptyLocalSessionIds: const {},
        cursorTotals: const {'quiet': 10},
      );
      expect(skipped, isEmpty);

      final dirty = assembleSessionsToSync(
        sessions: [quiet, grew],
        lastSyncAt: DateTime.utc(2026, 8, 1),
        syncedUnstampedIds: const {'grew'},
        emptyLocalSessionIds: const {},
        cursorTotals: const {'quiet': 10, 'grew': 4},
      );
      expect(dirty.map((session) => session.sessionId), ['grew']);
    });

    test('clearing history with no cursor is a cold start', () {
      expect(
        peerHistoryFetchMode(storedCursor: null, hasLocalMirroredRows: false),
        PeerHistoryFetchMode.cold,
      );
      expect(
        peerHistoryFetchMode(
          storedCursor: 'v1.3.abc',
          hasLocalMirroredRows: true,
        ),
        PeerHistoryFetchMode.incremental,
      );
      expect(
        peerHistoryFetchMode(storedCursor: null, hasLocalMirroredRows: true),
        PeerHistoryFetchMode.full,
      );
    });

    test('session list message_count is optional', () {
      expect(
        PeerRemoteSession.fromJson({
          'session_id': 's',
          'message_count': 3,
        })?.messageCount,
        3,
      );
      expect(
        PeerRemoteSession.fromJson({'session_id': 's'})?.messageCount,
        isNull,
      );
    });
  });
}

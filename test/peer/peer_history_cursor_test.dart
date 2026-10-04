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
        peerHistoryFetchMode(storedCursor: null),
        PeerHistoryFetchMode.rebuild,
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

    test('a paged reset rebuilds and drops peerhist rows the remote lost', () {
      final local = {for (var i = 0; i < 300; i++) 'peerhist_m$i'};
      var needsCleanup = false;
      final seen = <String>{};
      String? storedCursor = 'v1.300.old';

      void apply({
        required bool reset,
        required int from,
        required int length,
        required bool hasMore,
        required String cursor,
      }) {
        final step = peerHistoryStep(
          supportsCursor: true,
          reset: reset,
          messagesEmpty: length == 0,
          hasMore: hasMore,
          pageCursor: cursor,
          needsCleanup: needsCleanup,
        );
        expect(step.kind, PeerHistoryApplyKind.slice);
        if (step.restartCleanup) {
          needsCleanup = true;
          seen.clear();
          storedCursor = null;
        }
        seen.addAll([for (var i = 0; i < length; i++) 'peerhist_m${from + i}']);
        if (step.finishCleanup) {
          local.removeAll(peerHistoryRebuildDeletes(
            localPeerhistIds: local,
            seenIds: seen,
            preserveIds: const {},
          ));
        }
        if (step.cursorAction == PeerHistoryCursorAction.store) {
          storedCursor = cursor;
        }
      }

      apply(reset: true, from: 0, length: 200, hasMore: true, cursor: 'page-1');
      expect(storedCursor, isNull);
      expect(local.length, 300);
      apply(
        reset: false,
        from: 199,
        length: 51,
        hasMore: false,
        cursor: 'page-2',
      );
      expect(storedCursor, 'page-2');
      expect(local, {for (var i = 0; i < 250; i++) 'peerhist_m$i'});
    });

    test('an interrupted rebuild keeps the stale rows and no new cursor', () {
      var needsCleanup = false;
      String? storedCursor = 'v1.300.old';
      final seen = <String>{};
      final step = peerHistoryStep(
        supportsCursor: true,
        reset: true,
        messagesEmpty: false,
        hasMore: true,
        pageCursor: 'page-1',
        needsCleanup: needsCleanup,
      );
      expect(step.restartCleanup, isTrue);
      expect(step.cursorAction, PeerHistoryCursorAction.skip);
      expect(step.finishCleanup, isFalse);
      needsCleanup = true;
      seen.addAll([for (var i = 0; i < 200; i++) 'peerhist_m$i']);
      storedCursor = null;

      expect(
        peerHistoryFetchMode(storedCursor: storedCursor),
        PeerHistoryFetchMode.rebuild,
      );
      expect(needsCleanup, isTrue);
      expect(seen, isNot(contains('peerhist_m299')));
    });

    test(
        'an upgrade rebuild requests a limit and finishes only on the last page',
        () {
      final request = peerHistoryHistoryRequest(
        mode: PeerHistoryFetchMode.rebuild,
      );
      expect(request.cursor, isNull);
      expect(request.limit, kPeerHistoryPageLimit);
      final middle = peerHistoryStep(
        supportsCursor: true,
        reset: false,
        messagesEmpty: false,
        hasMore: true,
        pageCursor: 'page-1',
        needsCleanup: true,
      );
      expect(middle.cursorAction, PeerHistoryCursorAction.skip);
      expect(middle.finishCleanup, isFalse);
      final last = peerHistoryStep(
        supportsCursor: true,
        reset: false,
        messagesEmpty: false,
        hasMore: false,
        pageCursor: 'page-2',
        needsCleanup: true,
      );
      expect(last.cursorAction, PeerHistoryCursorAction.store);
      expect(last.finishCleanup, isTrue);
    });

    test('dropping the remote tail deletes the local last row on reset', () {
      final local = {for (var i = 0; i < 300; i++) 'peerhist_m$i'};
      final seen = {for (var i = 0; i < 299; i++) 'peerhist_m$i'};
      final step = peerHistoryStep(
        supportsCursor: true,
        reset: true,
        messagesEmpty: false,
        hasMore: false,
        pageCursor: 'v1.299.new',
        needsCleanup: false,
      );
      expect(step.restartCleanup, isTrue);
      expect(step.finishCleanup, isTrue);
      local.removeAll(peerHistoryRebuildDeletes(
        localPeerhistIds: local,
        seenIds: seen,
        preserveIds: const {},
      ));
      expect(local.contains('peerhist_m299'), isFalse);
      expect(local.length, 299);
    });

    test('an empty reset keeps local rows and stores a zero cursor', () {
      final step = peerHistoryStep(
        supportsCursor: true,
        reset: true,
        messagesEmpty: true,
        hasMore: false,
        pageCursor: 'v1.0.empty',
        needsCleanup: false,
      );
      expect(step.kind, PeerHistoryApplyKind.emptyReset);
      expect(step.cursorAction, PeerHistoryCursorAction.storeEmpty);
      expect(step.finishCleanup, isFalse);
      final quiet = assembleSessionsToSync(
        sessions: [
          PeerRemoteSession(
            sessionId: 'empty',
            updatedAt: DateTime.utc(2026, 1, 1),
            messageCount: 0,
          ),
        ],
        lastSyncAt: DateTime.utc(2026, 8, 1),
        syncedUnstampedIds: const {},
        emptyLocalSessionIds: const {},
        cursorTotals: const {'empty': 0},
      );
      expect(quiet, isEmpty);
      expect(
        peerHistoryFetchMode(storedCursor: ''),
        PeerHistoryFetchMode.rebuild,
      );
    });

    test('an old hub response is a full compare and does not store a cursor',
        () {
      final step = peerHistoryStep(
        supportsCursor: false,
        reset: false,
        messagesEmpty: false,
        hasMore: false,
        pageCursor: null,
        needsCleanup: false,
      );
      expect(step.kind, PeerHistoryApplyKind.full);
      expect(step.cursorAction, PeerHistoryCursorAction.skip);
      expect(step.finishCleanup, isFalse);
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

    test('clearing history with no cursor rebuilds from the start', () {
      expect(
        peerHistoryFetchMode(storedCursor: null),
        PeerHistoryFetchMode.rebuild,
      );
      expect(
        peerHistoryFetchMode(storedCursor: 'v1.3.abc'),
        PeerHistoryFetchMode.incremental,
      );
      expect(
        peerHistoryFetchMode(storedCursor: ''),
        PeerHistoryFetchMode.rebuild,
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

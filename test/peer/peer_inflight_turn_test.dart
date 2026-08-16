import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/services/peer_inflight_turn.dart';

void main() {
  group('clipAccumulated', () {
    test('returns short text unchanged', () {
      expect(clipAccumulated('hello', maxChars: 10), 'hello');
    });

    test('keeps the tail when clipping', () {
      expect(clipAccumulated('abcdefghij', maxChars: 4), 'ghij');
    });
  });

  group('isPeerInflightTurnExpired', () {
    PeerInflightTurnRecord rec({required int updatedAtMs}) => PeerInflightTurnRecord(
          requestId: 'r1',
          peerId: 'p',
          remoteAgentId: 'ra',
          localAgentId: 'la',
          channelId: 'ch',
          sessionId: 's',
          userMessageId: 'u1',
          userId: 'u',
          userName: 'U',
          agentName: 'A',
          receivedLength: 3,
          startedAtMs: updatedAtMs,
          updatedAtMs: updatedAtMs,
        );

    test('fresh record is not expired', () {
      final now = DateTime.utc(2026, 8, 14, 8);
      expect(
        isPeerInflightTurnExpired(
          rec(updatedAtMs: now.millisecondsSinceEpoch),
          now: now,
        ),
        isFalse,
      );
    });

    test('older than TTL is expired', () {
      final now = DateTime.utc(2026, 8, 14, 8);
      final old = now.subtract(const Duration(minutes: 26));
      expect(
        isPeerInflightTurnExpired(
          rec(updatedAtMs: old.millisecondsSinceEpoch),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('localMessageIdsToDeleteOnPeerHistorySync', () {
    const remote = {'peerhist_a', 'peerhist_b'};
    final remoteKeys = {
      peerHistoryRoleContentKey('user', 'hi'),
      peerHistoryRoleContentKey('agent', 'old answer'),
    };

    test('deletes stale peerhist ids missing from remote', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'peerhist_gone',
            senderType: 'agent',
            content: 'gone',
          ),
          PeerHistorySyncLocalRow(
            id: 'peerhist_a',
            senderType: 'user',
            content: 'hi',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
      );
      expect(deleted, {'peerhist_gone'});
    });

    test('keeps uuid user message whose content is not in remote', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'uuid-new',
            senderType: 'user',
            content: 'new question',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
      );
      expect(deleted, isEmpty);
    });

    test('deletes uuid message that remote already has as peerhist (first sync)', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'uuid-old',
            senderType: 'user',
            content: 'hi',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
      );
      expect(deleted, {'uuid-old'});
    });

    test('keeps inflight user message even when content matches remote', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'uuid-repeat',
            senderType: 'user',
            content: 'hi',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {'uuid-repeat'},
      );
      expect(deleted, isEmpty);
    });

    test('keeps streaming flush rows whose content is not covered remotely', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'partial-1',
            senderType: 'agent',
            content: 'Hello',
            metadataJson: '{"status":"streaming"}',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
        remoteAgentContents: const ['old answer'],
      );
      expect(deleted, isEmpty);
    });

    test('keeps preserved streaming row even when remote covers its content', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'partial-live',
            senderType: 'agent',
            content: 'Hello',
            metadataJson: '{"status":"streaming"}',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {'partial-live'},
        remoteAgentContents: const ['Hello world, full answer'],
      );
      expect(deleted, isEmpty);
    });

    test('deletes orphan streaming row covered by a remote agent message', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'partial-orphan',
            senderType: 'agent',
            content: 'Hello wor',
            metadataJson: '{"status":"streaming"}',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
        remoteAgentContents: const ['Hello world, full answer'],
      );
      expect(deleted, {'partial-orphan'});
    });

    test('deletes orphan streaming row whose content exactly equals remote', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'partial-eq',
            senderType: 'agent',
            content: 'old answer',
            metadataJson: '{"status": "streaming"}',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
        remoteAgentContents: const ['old answer'],
      );
      expect(deleted, {'partial-eq'});
    });

    test('keeps empty-content streaming row (nothing to match against)', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'partial-empty',
            senderType: 'agent',
            content: '',
            metadataJson: '{"status":"streaming"}',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
        remoteAgentContents: const ['old answer'],
      );
      expect(deleted, isEmpty);
    });

    test('content match tolerates trailing whitespace drift', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(
            id: 'uuid-old',
            senderType: 'user',
            content: 'hi\n',
          ),
        ],
        remoteIds: remote,
        remoteRoleContentKeys: remoteKeys,
        preserveIds: const {},
      );
      expect(deleted, {'uuid-old'});
    });
  });

  group('turn-linkage deletion (resume ↔ sync race)', () {
    // Remote transcript: prompt + answer. Local mirrors the prompt as a uuid
    // row and the reply as a uuid row whose content drifted from the remote.
    const transcript = [
      PeerHistoryRemoteEntry(role: 'user', content: 'hi'),
      PeerHistoryRemoteEntry(role: 'agent', content: 'Hello there!'),
    ];
    final keys = {
      peerHistoryRoleContentKey('user', 'hi'),
      peerHistoryRoleContentKey('agent', 'Hello there!'),
    };
    const remoteIds = {'peerhist_u', 'peerhist_a'};

    test('deletes local user prompt and its drifted local agent reply', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: 'Hello there!\n', // drifted — exact key would miss
            replyToId: 'u1',
          ),
        ],
        remoteIds: remoteIds,
        remoteRoleContentKeys: keys,
        preserveIds: const {},
        remoteTranscript: transcript,
      );
      expect(deleted, containsAll(['u1', 'a1']));
    });

    test('deletes linked agent reply even when content matches nothing remote', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: 'totally different local formatting',
            replyToId: 'u1',
          ),
        ],
        remoteIds: remoteIds,
        remoteRoleContentKeys: keys,
        preserveIds: const {},
        remoteTranscript: transcript,
      );
      expect(deleted, containsAll(['u1', 'a1']));
    });

    test('keeps agent reply when remote never answered the prompt', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: 'local-only reply',
            replyToId: 'u1',
          ),
        ],
        remoteIds: const {'peerhist_u'},
        remoteRoleContentKeys: {peerHistoryRoleContentKey('user', 'hi')},
        preserveIds: const {},
        remoteTranscript: const [
          PeerHistoryRemoteEntry(role: 'user', content: 'hi'),
        ],
      );
      expect(deleted, {'u1'});
    });

    test('keeps agent reply anchored to a preserved (inflight) user message', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: 'inflight answer so far',
            replyToId: 'u1',
          ),
        ],
        remoteIds: remoteIds,
        remoteRoleContentKeys: keys,
        preserveIds: const {'u1', 'a1'},
        remoteTranscript: transcript,
      );
      expect(deleted, isEmpty);
    });

    test('deletes linked streaming row even when prefix match fails', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: '⟳ thinking…', // splitter artifact, not a prefix
            metadataJson: '{"status":"streaming"}',
            replyToId: 'u1',
          ),
        ],
        remoteIds: remoteIds,
        remoteRoleContentKeys: keys,
        preserveIds: const {},
        remoteAgentContents: const ['Hello there!'],
        remoteTranscript: transcript,
      );
      expect(deleted, containsAll(['u1', 'a1']));
    });

    test('does not link agent rows whose anchor is not the superseded prompt', () {
      final deleted = localMessageIdsToDeleteOnPeerHistorySync(
        localRows: const [
          PeerHistorySyncLocalRow(id: 'u1', senderType: 'user', content: 'hi'),
          PeerHistorySyncLocalRow(
            id: 'a1',
            senderType: 'agent',
            content: 'reply to something else',
            replyToId: 'some-other-message',
          ),
        ],
        remoteIds: remoteIds,
        remoteRoleContentKeys: keys,
        preserveIds: const {},
        remoteTranscript: transcript,
      );
      expect(deleted, {'u1'});
    });
  });

  group('peerSyncedRowCoversFinalContent', () {
    test('equal after trim', () {
      expect(peerSyncedRowCoversFinalContent('Hello\n', 'Hello'), isTrue);
    });

    test('remote covers local (clipped resume delta)', () {
      expect(peerSyncedRowCoversFinalContent('Hello world', 'Hello'), isTrue);
    });

    test('local covers remote (Stopped suffix)', () {
      expect(
        peerSyncedRowCoversFinalContent('Hello', 'Hello\n\n[Stopped]'),
        isTrue,
      );
    });

    test('empty on either side never matches', () {
      expect(peerSyncedRowCoversFinalContent('', 'Hello'), isFalse);
      expect(peerSyncedRowCoversFinalContent('Hello', ''), isFalse);
    });

    test('unrelated content does not match', () {
      expect(peerSyncedRowCoversFinalContent('Bye', 'Hello'), isFalse);
    });
  });

  group('PeerInflightTurnRecord map roundtrip', () {
    test('survives toMap/fromMap', () {
      final rec = PeerInflightTurnRecord(
        requestId: 'r1',
        peerId: 'p',
        remoteAgentId: 'ra',
        localAgentId: 'la',
        channelId: 'ch',
        sessionId: 's',
        userMessageId: 'u1',
        userId: 'u',
        userName: 'U',
        agentName: 'A',
        receivedLength: 12,
        accumulatedContent: 'Hello world',
        partialMessageId: 'partial',
        startedAtMs: 1,
        updatedAtMs: 2,
      );
      final copy = PeerInflightTurnRecord.fromMap(rec.toMap());
      expect(copy.requestId, rec.requestId);
      expect(copy.receivedLength, 12);
      expect(copy.accumulatedContent, 'Hello world');
      expect(copy.partialMessageId, 'partial');
      expect(copy.channelId, 'ch');
    });
  });
}

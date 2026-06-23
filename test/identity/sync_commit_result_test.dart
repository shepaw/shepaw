import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_commit_result.dart';
import 'package:shepaw/identity/utils/sync_lww.dart';

void main() {
  group('SyncCommitResult.shouldAckOutboundCommitResponse', () {
    test('does not ack pending_relay responses', () {
      expect(
        SyncCommitResult.shouldAckOutboundCommitResponse({
          'ok': true,
          'applied': false,
          'pending_relay': true,
        }),
        isFalse,
      );
    });

    test('acks applied and stale responses', () {
      expect(
        SyncCommitResult.shouldAckOutboundCommitResponse({'ok': true, 'applied': true}),
        isTrue,
      );
      expect(
        SyncCommitResult.shouldAckOutboundCommitResponse({'ok': true, 'stale': true, 'applied': false}),
        isTrue,
      );
    });
  });

  group('SyncCommitResult.shouldAckBackupRelayResponse', () {
    test('acks applied commits', () {
      expect(
        SyncCommitResult.shouldAckBackupRelayResponse({'ok': true, 'applied': true}),
        isTrue,
      );
    });

    test('does not ack stale commits', () {
      expect(
        SyncCommitResult.shouldAckBackupRelayResponse({'ok': true, 'stale': true, 'applied': false}),
        isFalse,
      );
    });

    test('does not ack failed commits', () {
      expect(
        SyncCommitResult.shouldAckBackupRelayResponse({'ok': false}),
        isFalse,
      );
    });

    test('acks legacy ok responses without applied/stale fields', () {
      expect(
        SyncCommitResult.shouldAckBackupRelayResponse({'ok': true}),
        isTrue,
      );
    });
  });

  group('Delete stale via SyncLww (same rules as upsert)', () {
    test('older delete is stale when entity was updated later', () {
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 100,
          existingWallTimeMs: 200,
          incomingEventId: 'msg:x:del:100',
          existingEventId: 'msg:x',
        ),
        isTrue,
      );
    });

    test('newer delete is not stale', () {
      expect(
        SyncLww.isIncomingStale(
          incomingWallTimeMs: 300,
          existingWallTimeMs: 200,
          incomingEventId: 'msg:x:del:300',
          existingEventId: 'msg:x',
        ),
        isFalse,
      );
    });
  });
}

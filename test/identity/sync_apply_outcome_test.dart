import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_apply_outcome.dart';
import 'package:shepaw/identity/models/sync_domain_cursor.dart';
import 'package:shepaw/identity/models/sync_event.dart';

void main() {
  group('SyncApplyOutcome pull cursor semantics', () {
    test('stale events should still advance composite cursor', () {
      const cursor = SyncDomainCursor(wallTimeMs: 100, lastEventId: 'msg:a');
      var next = cursor;

      final staleEvent = SyncEvent(
        eventId: 'msg:b',
        domain: 'message',
        payload: {'id': 'b'},
        wallTimeMs: 100,
        originDeviceId: 'remote',
      );

      const outcome = SyncApplyOutcome.staleSkipped;
      switch (outcome) {
        case SyncApplyOutcome.applied:
          next = next.advance(staleEvent);
        case SyncApplyOutcome.staleSkipped:
        case SyncApplyOutcome.invalidSkipped:
          next = next.advance(staleEvent);
      }

      expect(next.wallTimeMs, 100);
      expect(next.lastEventId, 'msg:b');
      expect(SyncDomainCursor.isEventAfter(staleEvent, cursor), isTrue);
      expect(SyncDomainCursor.isEventAfter(staleEvent, next), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_apply_outcome.dart';
import 'package:shepaw/identity/models/sync_domain_cursor.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/utils/sync_query_limits.dart';

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
          next = next.advance(staleEvent);
        case SyncApplyOutcome.invalidSkipped:
          break;
      }

      expect(next.wallTimeMs, 100);
      expect(next.lastEventId, 'msg:b');
      expect(SyncDomainCursor.isEventAfter(staleEvent, cursor), isTrue);
      expect(SyncDomainCursor.isEventAfter(staleEvent, next), isFalse);
    });

    test('invalid events should not advance composite cursor', () {
      const cursor = SyncDomainCursor(wallTimeMs: 100, lastEventId: 'msg:a');
      var next = cursor;

      final invalidEvent = SyncEvent(
        eventId: 'msg:bad',
        domain: 'message',
        payload: {},
        wallTimeMs: 101,
        originDeviceId: 'remote',
      );

      const outcome = SyncApplyOutcome.invalidSkipped;
      switch (outcome) {
        case SyncApplyOutcome.applied:
          next = next.advance(invalidEvent);
        case SyncApplyOutcome.staleSkipped:
          next = next.advance(invalidEvent);
        case SyncApplyOutcome.invalidSkipped:
          break;
      }

      expect(next, cursor);
    });
  });

  group('SyncQueryLimits', () {
    test('clampLimit caps oversized query requests', () {
      expect(SyncQueryLimits.clampLimit(null), SyncQueryLimits.defaultLimit);
      expect(SyncQueryLimits.clampLimit(9999), SyncQueryLimits.maxLimit);
      expect(SyncQueryLimits.clampLimit(0), 1);
    });
  });
}

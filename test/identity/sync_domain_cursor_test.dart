import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_domain_cursor.dart';
import 'package:shepaw/identity/models/sync_event.dart';

void main() {
  group('SyncDomainCursor', () {
    test('parse legacy int-only cursor', () {
      expect(SyncDomainCursor.parse('12345').wallTimeMs, 12345);
      expect(SyncDomainCursor.parse('12345').lastEventId, '');
    });

    test('parse composite cursor', () {
      final c = SyncDomainCursor.parse('100|msg:a');
      expect(c.wallTimeMs, 100);
      expect(c.lastEventId, 'msg:a');
    });

    test('isEventAfter handles same millisecond tie-break', () {
      const cursor = SyncDomainCursor(wallTimeMs: 100, lastEventId: 'msg:a');
      final before = SyncEvent(
        eventId: 'msg:a',
        domain: 'message',
        payload: {'id': 'a'},
        wallTimeMs: 100,
        originDeviceId: 'dev',
      );
      final after = SyncEvent(
        eventId: 'msg:b',
        domain: 'message',
        payload: {'id': 'b'},
        wallTimeMs: 100,
        originDeviceId: 'dev',
      );
      expect(SyncDomainCursor.isEventAfter(before, cursor), isFalse);
      expect(SyncDomainCursor.isEventAfter(after, cursor), isTrue);
    });
  });
}

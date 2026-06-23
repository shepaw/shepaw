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

    test('upsert revision with same wall time gets distinct event id', () {
      const ms = 100;
      final first = SyncEvent.messageEvent(
        messageRow: {
          'id': 'm1',
          'channel_id': 'c1',
          'content': 'v1',
          'created_at': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
        },
        originDeviceId: 'dev',
      );
      final second = SyncEvent.messageEvent(
        messageRow: {
          'id': 'm1',
          'channel_id': 'c1',
          'content': 'v2',
          'created_at': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
        },
        originDeviceId: 'dev',
      );
      expect(first.eventId, startsWith('msg:m1@$ms#'));
      expect(second.eventId, isNot(first.eventId));

      final cursor = SyncDomainCursor(wallTimeMs: ms, lastEventId: first.eventId);
      final third = SyncEvent.messageEvent(
        messageRow: {
          'id': 'm1',
          'channel_id': 'c1',
          'content': 'v3',
          'created_at': DateTime.fromMillisecondsSinceEpoch(ms).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(ms + 1).toIso8601String(),
        },
        originDeviceId: 'dev',
      );
      expect(SyncDomainCursor.isEventAfter(third, cursor), isTrue);
    });

    test('pageEventsAfter returns events after cursor in stable order', () {
      const cursor = SyncDomainCursor(wallTimeMs: 100, lastEventId: 'msg:a');
      final events = [
        SyncEvent(
          eventId: 'msg:a',
          domain: 'message',
          payload: {'id': 'a'},
          wallTimeMs: 100,
          originDeviceId: 'dev',
        ),
        SyncEvent(
          eventId: 'msg:b',
          domain: 'message',
          payload: {'id': 'b'},
          wallTimeMs: 100,
          originDeviceId: 'dev',
        ),
        SyncEvent(
          eventId: 'msg:c',
          domain: 'message',
          payload: {'id': 'c'},
          wallTimeMs: 101,
          originDeviceId: 'dev',
        ),
      ];

      final page = SyncDomainCursor.pageEventsAfter(
        events: events,
        cursor: cursor,
        limit: 10,
      );

      expect(page.map((e) => e.eventId).toList(), ['msg:b', 'msg:c']);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_event.dart';

void main() {
  group('SyncEvent', () {
    test('delete action round-trips through JSON', () {
      const event = SyncEvent(
        eventId: 'msg:abc:del:100',
        domain: 'message',
        action: SyncEventAction.delete,
        payload: {'id': 'abc', 'channel_id': 'ch1'},
        wallTimeMs: 100,
        originDeviceId: 'dev1',
      );
      final restored = SyncEvent.fromJson(event.toJson());
      expect(restored.action, SyncEventAction.delete);
      expect(restored.payload['id'], 'abc');
    });

    test('legacy JSON without action defaults to upsert', () {
      final restored = SyncEvent.fromJson({
        'event_id': 'msg:1',
        'domain': 'message',
        'payload': {'id': '1', 'created_at': '2026-01-01T00:00:00.000'},
        'wall_time_ms': 1,
        'origin_device_id': 'dev',
      });
      expect(restored.action, SyncEventAction.upsert);
    });
  });
}

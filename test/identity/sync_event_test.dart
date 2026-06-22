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

    test('agent event round-trips through JSON', () {
      final event = SyncEvent.agentEvent(
        agentRow: {
          'id': 'a1',
          'name': 'Bot',
          'updated_at': 1000,
          'created_at': 900,
        },
        originDeviceId: 'dev1',
      );
      final restored = SyncEvent.fromJson(event.toJson());
      expect(restored.domain, 'agent');
      expect(restored.payload['id'], 'a1');
    });

    test('she_memory event round-trips through JSON', () {
      final event = SyncEvent.sheMemoryEvent(
        row: {'key': 'soul', 'value': 'test', 'updated_at': 2000},
        originDeviceId: 'dev1',
      );
      final restored = SyncEvent.fromJson(event.toJson());
      expect(restored.domain, 'she_memory');
      expect(restored.payload['key'], 'soul');
    });

    test('cognition self event includes kind', () {
      final event = SyncEvent.cognitionSelfEvent(
        row: {
          'agent_id': 'she-builtin-agent-001',
          'soul': 'hello',
          'updated_at': 3000,
          'created_at': 1000,
        },
        originDeviceId: 'dev1',
      );
      final restored = SyncEvent.fromJson(event.toJson());
      expect(restored.domain, 'cognition');
      expect(restored.payload['kind'], 'self');
    });
  });
}

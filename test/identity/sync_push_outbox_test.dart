import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/services/sync_protocol_service.dart';
import 'package:shepaw/identity/utils/sync_push_backoff.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_push_test').path;
      }
      return null;
    });
  });

  group('sync push outbox', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      await db.switchAccount('test-push-${DateTime.now().microsecondsSinceEpoch}');
      await db.database;
      SyncProtocolService.instance.stop();
      SyncProtocolService.instance.start();
    });

    tearDown(() async {
      SyncProtocolService.instance.stop();
      await db.close();
    });

    test('partial push ack prunes applied events and retries failures', () async {
      const deviceId = 'app-device-1';
      const pushId = 'push-partial';

      final okEvent = {
        'event_id': 'msg:ok@100',
        'domain': 'message',
        'action': 'upsert',
        'payload': {'id': 'ok'},
        'wall_time_ms': 100,
        'origin_device_id': 'primary',
      };
      final badEvent = {
        'event_id': 'msg:bad@200',
        'domain': 'message',
        'action': 'upsert',
        'payload': {'id': 'bad'},
        'wall_time_ms': 200,
        'origin_device_id': 'primary',
      };

      await db.enqueueSyncPushOutbox(
        pushId: pushId,
        targetDeviceId: deviceId,
        payloadJson: '[${jsonEncode(okEvent)},${jsonEncode(badEvent)}]',
      );

      await SyncProtocolService.instance.dispatchControlForTest(
        'peer-primary',
        {
          'type': 'sync_push_ack',
          'push_id': pushId,
          'ok': false,
          'failed_event_ids': ['msg:bad@200'],
        },
      );

      final row = await db.getSyncPushOutboxRow(pushId);
      expect(row?['acked'], 0);
      expect(row?['retry_count'], 1);
      final remaining = jsonDecode(row!['payload'] as String) as List;
      expect(remaining.length, 1);
      expect(remaining.first['event_id'], 'msg:bad@200');
    });

    test('push dead-letter after max retries', () async {
      const deviceId = 'app-device-1';
      const pushId = 'push-dead';

      await db.enqueueSyncPushOutbox(
        pushId: pushId,
        targetDeviceId: deviceId,
        payloadJson: '[{"event_id":"msg:x@1","domain":"message","payload":{"id":"x"},"wall_time_ms":1,"origin_device_id":"p"}]',
      );

      for (var i = 0; i < SyncPushBackoff.maxDeadLetterRetries - 1; i++) {
        await db.scheduleSyncPushRetry(pushId);
      }

      await SyncProtocolService.instance.dispatchControlForTest(
        'peer-primary',
        {
          'type': 'sync_push_ack',
          'push_id': pushId,
          'ok': false,
          'failed_event_ids': ['msg:x@1'],
        },
      );

      final row = await db.getSyncPushOutboxRow(pushId);
      expect(row?['acked'], 1);
      expect(await db.listPendingSyncPushForDevice(deviceId, bypassBackoff: true), isEmpty);
    });

    test('scheduleSyncPushRetry defers pending row until next_retry_at', () async {
      const deviceId = 'app-device-1';
      const pushId = 'push-1';

      await db.enqueueSyncPushOutbox(
        pushId: pushId,
        targetDeviceId: deviceId,
        payloadJson: '[]',
      );

      await db.scheduleSyncPushRetry(pushId);

      final blocked = await db.listPendingSyncPushForDevice(deviceId);
      expect(blocked, isEmpty);

      final bypassed = await db.listPendingSyncPushForDevice(
        deviceId,
        bypassBackoff: true,
      );
      expect(bypassed.length, 1);
      expect(bypassed.first['retry_count'], 1);
      expect(bypassed.first['next_retry_at'], greaterThan(DateTime.now().millisecondsSinceEpoch));
    });
  });
}

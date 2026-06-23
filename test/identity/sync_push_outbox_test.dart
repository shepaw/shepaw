import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
    });

    tearDown(() async {
      await db.close();
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

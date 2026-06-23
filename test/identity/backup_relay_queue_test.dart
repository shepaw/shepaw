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
        return Directory.systemTemp.createTempSync('shepaw_relay_test').path;
      }
      return null;
    });
  });

  group('backup relay queue', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      await db.switchAccount('test-relay-${DateTime.now().microsecondsSinceEpoch}');
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test('enqueueBackupRelayEvent skips already relayed rows', () async {
      const id = 'msg:test:1';
      const payload = '{"event_id":"msg:test:1"}';

      await db.enqueueBackupRelayEvent(id: id, payloadJson: payload);
      await db.markBackupRelayAcked(id);

      await db.enqueueBackupRelayEvent(id: id, payloadJson: '{"updated":true}');

      final pending = await db.listPendingBackupRelay(limit: 10);
      expect(pending, isEmpty);
    });

    test('enqueueBackupRelayEvent replaces pending row payload', () async {
      const id = 'msg:test:2';

      await db.enqueueBackupRelayEvent(id: id, payloadJson: '{"v":1}');
      await db.enqueueBackupRelayEvent(id: id, payloadJson: '{"v":2}');

      final pending = await db.listPendingBackupRelay(limit: 10);
      expect(pending.length, 1);
      expect(pending.first['payload'], '{"v":2}');
      expect(pending.first['relayed'], 0);
    });
  });
}

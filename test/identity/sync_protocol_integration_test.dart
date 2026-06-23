import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/sync_engine.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 协议层 relay / reconcile 集成：DB + SyncEngine，不依赖 P2P mock。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_proto_test').path;
      }
      return null;
    });
  });

  group('backup relay reconcile integration', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      await db.switchAccount('test-proto-${DateTime.now().microsecondsSinceEpoch}');
      await db.database;
    });

    tearDown(() async {
      await db.close();
    });

    test('pull-aligned entity state discards superseded relay row', () async {
      const messageId = 'msg-relay-1';
      const entityKey = messageId;
      const newerMs = 5000;
      const olderMs = 1000;

      await db.upsertEntitySyncState(
        domain: 'message',
        entityKey: entityKey,
        wallTimeMs: newerMs,
        eventId: messageId,
        originDeviceId: 'primary-1',
      );

      final staleEvent = SyncEvent.messageEvent(
        messageRow: {
          'id': messageId,
          'channel_id': 'ch-1',
          'sender_id': 'app-1',
          'sender_name': 'App',
          'content': 'old body',
          'created_at': DateTime.fromMillisecondsSinceEpoch(olderMs).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(olderMs).toIso8601String(),
        },
        originDeviceId: 'app-1',
      );

      await db.enqueueBackupRelayEvent(
        id: staleEvent.eventId,
        payloadJson: staleEvent.toJsonString(),
      );

      expect(await SyncEngine.instance.isEventSupersededByLocalState(staleEvent), isTrue);

      final pending = await db.listPendingBackupRelay(limit: 10);
      expect(pending.length, 1);

      for (final row in pending) {
        final rowId = row['id'] as String;
        final payloadRaw = row['payload'] as String? ?? '';
        final event = SyncEvent.fromJson(
          jsonDecode(payloadRaw) as Map<String, dynamic>,
        );
        if (await SyncEngine.instance.isEventSupersededByLocalState(event)) {
          await db.markBackupRelayAcked(rowId);
        }
      }

      expect(await db.listPendingBackupRelay(limit: 10), isEmpty);
    });

    test('newer relay event is not discarded before apply', () async {
      const messageId = 'msg-relay-2';
      const existingMs = 1000;
      const newerMs = 9000;

      await db.upsertEntitySyncState(
        domain: 'message',
        entityKey: messageId,
        wallTimeMs: existingMs,
        eventId: 'msg-old',
        originDeviceId: 'primary-1',
      );

      final freshEvent = SyncEvent.messageEvent(
        messageRow: {
          'id': messageId,
          'channel_id': 'ch-1',
          'sender_id': 'app-1',
          'sender_name': 'App',
          'content': 'new body',
          'created_at': DateTime.fromMillisecondsSinceEpoch(newerMs).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(newerMs).toIso8601String(),
        },
        originDeviceId: 'app-1',
      );

      expect(await SyncEngine.instance.isEventSupersededByLocalState(freshEvent), isFalse);
    });
  });
}

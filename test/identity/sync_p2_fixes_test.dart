import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/models/sync_domain_cursor.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
import 'package:shepaw/identity/services/sync_engine.dart';
import 'package:shepaw/identity/services/sync_fanout_service.dart';
import 'package:shepaw/identity/services/sync_local_write_hook.dart';
import 'package:shepaw/identity/services/sync_protocol_service.dart';
import 'package:shepaw/identity/utils/sync_query_limits.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sync_p2p_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_p2_fixes_test').path;
      }
      return null;
    });
  });

  group('P2 sync_query', () {
    late SyncP2pTestHarness harness;

    tearDown(() async {
      await harness.dispose();
    });

    test('queryMessageEvents sets hasMore when page is full', () async {
      harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.primary,
        localDeviceId: SyncP2pTestIds.primaryDevice,
        localPeerId: SyncP2pTestIds.primaryPeer,
      );

      const iso = '2026-06-01T12:00:00.000';
      for (var i = 0; i < 3; i++) {
        await harness.db.upsertMessageFromSync({
          'id': 'msg-page-$i',
          'channel_id': 'ch-page',
          'sender_id': SyncP2pTestIds.appDevice,
          'sender_name': 'App',
          'content': 'body $i',
          'created_at': iso,
          'updated_at': iso,
        });
      }

      final page = await SyncEngine.instance.queryMessageEvents(sinceMs: 0, limit: 2);
      expect(page.events.length, 2);
      expect(page.hasMore, isTrue);
    });

    test('sync_query handler clamps oversized limit and returns has_more', () async {
      harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.primary,
        localDeviceId: SyncP2pTestIds.primaryDevice,
        localPeerId: SyncP2pTestIds.primaryPeer,
      );

      harness.router.noteSender(SyncP2pTestIds.appPeer);
      await SyncProtocolService.instance.dispatchControlForTest(
        SyncP2pTestIds.appPeer,
        {
          'type': 'sync_query',
          'request_id': 'req-limit-cap',
          'domain': 'message',
          'since_ms': 0,
          'limit': 99999,
        },
      );

      final resp = harness.router.lastSentTo(SyncP2pTestIds.appPeer)?.payload;
      expect(resp?['error'], isNull);
      expect(resp?['has_more'], isA<bool>());
      expect(SyncQueryLimits.clampLimit(99999), SyncQueryLimits.maxLimit);
    });
  });

  group('P2 invalid event quarantine', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      final accountId = 'p2-invalid-${DateTime.now().microsecondsSinceEpoch}';
      await db.switchAccount(accountId);
      await db.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 8));
      await db.upsertIdentityUser(
        id: SyncP2pTestIds.userId,
        displayName: 'Test',
        publicKey: key,
        createdAt: now,
      );
      await db.upsertSpiritPet(
        id: SyncP2pTestIds.petId,
        userId: SyncP2pTestIds.userId,
        name: 'She',
        publicKey: key,
        agentId: 'agent-test',
        createdAt: now,
      );
      await db.upsertOwnedDevice(
        OwnedDeviceRecord(
          id: 'rec-app',
          deviceId: SyncP2pTestIds.appDevice,
          deviceName: 'App',
          role: DeviceRole.app,
          transportPublicKey: key,
          fingerprint: 'fp-app',
          userId: SyncP2pTestIds.userId,
          petId: SyncP2pTestIds.petId,
          isLocal: true,
          trustedAt: now,
          lastSeenAt: now,
        ),
      );
      await AccountIdentityService.instance.activateAccountScopeForTests(accountId);
    });

    tearDown(() async {
      AccountIdentityService.instance.resetIdentityStateForTests();
      await db.close();
    });

    test('invalid apply quarantines event and does not advance cursor', () async {
      const cursorBefore = SyncDomainCursor(wallTimeMs: 0);
      final invalid = SyncEvent(
        eventId: 'msg:bad@100#abc',
        domain: 'message',
        payload: {},
        wallTimeMs: 100,
        originDeviceId: SyncP2pTestIds.appDevice,
      );
      final valid = SyncEvent.messageEvent(
        messageRow: {
          'id': 'msg-good',
          'channel_id': 'ch-1',
          'content': 'ok',
          'created_at': '2026-06-01T12:00:01.000',
          'updated_at': '2026-06-01T12:00:01.000',
        },
        originDeviceId: SyncP2pTestIds.appDevice,
      );

      final after = await SyncEngine.instance.applyMessageEvents([invalid, valid]);
      expect(await db.isInvalidSyncEventSkipped('message', invalid.eventId), isTrue);
      expect(after.wallTimeMs, greaterThanOrEqualTo(valid.wallTimeMs));
      expect(SyncDomainCursor.isEventAfter(valid, cursorBefore), isTrue);
    });
  });

  group('P2 read debounce', () {
    test('flushAllPendingDebouncedSync dispatches staged read rows once', () async {
      SyncLocalWriteHook.onMessageReadStateChanged(
        messageRow: {
          'id': 'm-read-1',
          'channel_id': 'ch-read',
          'content': 'hello',
        },
        updatedAt: '2026-06-01T12:00:00.000',
        isRead: 1,
      );

      await SyncLocalWriteHook.flushAllPendingDebouncedSync();
    });
  });

  group('P2 fanout split-primary guard', () {
    test('fanout skips when local is not user-elected primary', () async {
      final db = LocalDatabaseService();
      await db.close();
      final accountId = 'p2-fanout-${DateTime.now().microsecondsSinceEpoch}';
      await db.switchAccount(accountId);
      await db.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 2));
      await db.upsertIdentityUser(
        id: SyncP2pTestIds.userId,
        displayName: 'Test',
        publicKey: key,
        createdAt: now,
      );
      await db.upsertSpiritPet(
        id: SyncP2pTestIds.petId,
        userId: SyncP2pTestIds.userId,
        name: 'She',
        publicKey: key,
        agentId: 'agent-test',
        createdAt: now,
      );
      await db.upsertOwnedDevice(
        OwnedDeviceRecord(
          id: 'rec-primary',
          deviceId: SyncP2pTestIds.primaryDevice,
          deviceName: 'Primary',
          role: DeviceRole.primary,
          transportPublicKey: key,
          fingerprint: 'fp-primary',
          userId: SyncP2pTestIds.userId,
          petId: SyncP2pTestIds.petId,
          isLocal: true,
          trustedAt: now,
          lastSeenAt: now,
        ),
      );
      await db.setIdentitySyncState(
        'user_elected_primary_device_id',
        'device-other-primary',
      );
      await AccountIdentityService.instance.activateAccountScopeForTests(accountId);

      SyncProtocolService.instance.stop();
      SyncProtocolService.instance.start();

      final event = SyncEvent.messageEvent(
        messageRow: {
          'id': 'msg-fanout',
          'channel_id': 'ch-1',
          'content': 'x',
          'created_at': '2026-06-01T12:00:00.000',
          'updated_at': '2026-06-01T12:00:00.000',
        },
        originDeviceId: SyncP2pTestIds.primaryDevice,
      );

      await SyncFanoutService.fanout(event);
      final conn = await db.database;
      final pending = await conn.query('identity_sync_push_outbox');
      expect(pending, isEmpty);

      AccountIdentityService.instance.resetIdentityStateForTests();
      SyncProtocolService.instance.stop();
      await db.close();
    });
  });
}

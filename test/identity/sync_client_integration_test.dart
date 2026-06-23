import 'dart:io';

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/sync_client_service.dart';
import 'package:shepaw/identity/services/sync_protocol_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/sync_p2p_test_harness.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_client_test_root').path;
      }
      return null;
    });
  });

  group('SyncClientService integration', () {
    test('backup relay stale event triggers pull from Primary', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);
      harness.startSyncClient();

      SyncProtocolService.instance.signalBackupRelayStaleForTest();
      await harness.waitForSyncClientIdle();

      final queries = harness.router
          .sentTo(SyncP2pTestIds.primaryPeer)
          .where((m) => m.type == 'sync_query')
          .toList();
      expect(queries, isNotEmpty);
      expect(
        queries.map((q) => q.payload['domain']).toSet(),
        containsAll(['message', 'channel']),
      );
    });

    test('relay stale pull then reconcile discards superseded relay rows', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);
      harness.startSyncClient();

      const messageId = 'msg-client-reconcile';
      const newerMs = 9000;
      const olderMs = 1000;

      await harness.db.upsertEntitySyncState(
        domain: 'message',
        entityKey: messageId,
        wallTimeMs: newerMs,
        eventId: messageId,
        originDeviceId: SyncP2pTestIds.primaryDevice,
      );

      final staleEvent = SyncEvent.messageEvent(
        messageRow: {
          'id': messageId,
          'channel_id': 'ch-p2p',
          'sender_id': SyncP2pTestIds.appDevice,
          'sender_name': 'App',
          'content': 'old',
          'created_at': DateTime.fromMillisecondsSinceEpoch(olderMs).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(olderMs).toIso8601String(),
        },
        originDeviceId: SyncP2pTestIds.appDevice,
      );
      await harness.db.enqueueBackupRelayEvent(
        id: staleEvent.eventId,
        payloadJson: staleEvent.toJsonString(),
      );
      expect(await harness.db.listPendingBackupRelay(limit: 10), isNotEmpty);

      SyncProtocolService.instance.signalBackupRelayStaleForTest();
      await harness.waitForSyncClientIdle();

      expect(await harness.db.listPendingBackupRelay(limit: 10), isEmpty);
      expect(
        harness.router.sentTo(SyncP2pTestIds.primaryPeer)
            .any((m) => m.type == 'sync_query'),
        isTrue,
      );
    });

    test('pull applies message event returned by Primary query', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);
      harness.startSyncClient();

      const messageId = 'msg-from-primary';
      const wallTimeMs = 12000;
      final event = SyncEvent.messageEvent(
        messageRow: {
          'id': messageId,
          'channel_id': 'ch-p2p',
          'sender_id': SyncP2pTestIds.primaryDevice,
          'sender_name': 'Primary',
          'content': 'authoritative body',
          'created_at': DateTime.fromMillisecondsSinceEpoch(wallTimeMs).toIso8601String(),
          'updated_at': DateTime.fromMillisecondsSinceEpoch(wallTimeMs).toIso8601String(),
        },
        originDeviceId: SyncP2pTestIds.primaryDevice,
      );

      harness.router.onPrimaryQuery = (_, query) async {
        if (query['domain'] == 'message') {
          return {
            'type': 'sync_query_resp',
            'request_id': query['request_id'],
            'events': [event.toJson()],
          };
        }
        return {
          'type': 'sync_query_resp',
          'request_id': query['request_id'],
          'events': <Map<String, dynamic>>[],
        };
      };

      await SyncClientService.instance.pullFromPrimaryAfterRelayStaleForTest();
      await harness.waitForSyncClientIdle();

      final row = await harness.db.getMessageById(messageId, fetchRemote: false);
      expect(row, isNotNull);
      expect(row!['content'], 'authoritative body');
    });

    test('App does not sync_query Backup when Primary is offline', () async {
      final harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.app,
        localDeviceId: SyncP2pTestIds.appDevice,
        localPeerId: SyncP2pTestIds.appPeer,
      );
      addTearDown(harness.dispose);

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 6));
      await harness.db.upsertOwnedDevice(
        OwnedDeviceRecord(
          id: 'rec-backup-for-app',
          deviceId: SyncP2pTestIds.backupDevice,
          deviceName: 'Backup',
          role: DeviceRole.backup,
          transportPublicKey: key,
          fingerprint: 'fp-backup',
          userId: SyncP2pTestIds.userId,
          petId: SyncP2pTestIds.petId,
          isLocal: false,
          trustedAt: now,
          lastSeenAt: now,
        ),
      );

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: false);
      harness.router.setConnected(SyncP2pTestIds.backupPeer, connected: true);
      harness.startSyncClient();

      await SyncClientService.instance.onStoragePeerConnectedForTest(
        SyncP2pTestIds.backupPeer,
      );
      await harness.waitForSyncClientIdle();

      final backupQueries = harness.router
          .sentTo(SyncP2pTestIds.backupPeer)
          .where((m) => m.type == 'sync_query')
          .toList();
      expect(backupQueries, isEmpty);
    });
  });
}

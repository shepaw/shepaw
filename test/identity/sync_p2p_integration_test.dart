import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/sync_commit_result.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/sync_engine.dart';
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
        return Directory.systemTemp.createTempSync('shepaw_p2p_test_root').path;
      }
      return null;
    });
  });

  group('Sync P2P protocol integration', () {
    test('App commit while Primary offline → pending_relay, drain after connect', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: false);

      final resp = await harness.commitFromApp(messageId: 'msg-relay-drain');
      expect(resp?['ok'], isTrue);
      expect(resp?['pending_relay'], isTrue);
      expect(
        SyncCommitResult.shouldAckOutboundCommitResponse(resp),
        isFalse,
      );

      final pending = await harness.db.listPendingBackupRelay(limit: 10);
      expect(pending.length, 1);
      expect(pending.first['id'], 'msg:msg-relay-drain');

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: true);
      harness.router.onPrimaryCommit = (from, commit) async {
        expect(commit['event'], isNotNull);
        return {
          'type': 'sync_commit_resp',
          'request_id': commit['request_id'],
          'ok': true,
          'applied': true,
        };
      };

      await SyncProtocolService.instance.drainBackupRelayQueueForTest(
        SyncP2pTestIds.primaryPeer,
      );

      expect(await harness.db.listPendingBackupRelay(limit: 10), isEmpty);
      expect(
        harness.router.sentTo(SyncP2pTestIds.primaryPeer)
            .any((m) => m.type == 'sync_commit'),
        isTrue,
      );
    });

    test('inline forward stale from Primary signals backup relay stale', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: true);
      harness.router.onPrimaryCommit = (_, commit) async {
        return {
          'type': 'sync_commit_resp',
          'request_id': commit['request_id'],
          'ok': true,
          'applied': false,
          'stale': true,
        };
      };

      var staleSignaled = false;
      final sub = SyncProtocolService.instance.backupRelayStaleEvents.listen((_) {
        staleSignaled = true;
      });
      addTearDown(sub.cancel);

      final resp = await harness.commitFromApp(messageId: 'msg-inline-stale');
      expect(resp?['stale'], isTrue);
      expect(resp?['ok'], isTrue);
      expect(staleSignaled, isTrue);
      expect(await harness.db.listPendingBackupRelay(limit: 10), isEmpty);
    });

    test('Primary connect hook drains pending relay via onStoragePeerConnected', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: false);
      await harness.commitFromApp(messageId: 'msg-connect-drain');
      expect(await harness.db.listPendingBackupRelay(limit: 10), isNotEmpty);

      harness.router.setConnected(SyncP2pTestIds.primaryPeer, connected: true);
      harness.router.onPrimaryCommit = (_, commit) async {
        return {
          'type': 'sync_commit_resp',
          'request_id': commit['request_id'],
          'ok': true,
          'applied': true,
        };
      };

      await SyncProtocolService.instance.onStoragePeerConnectedForTest(
        SyncP2pTestIds.primaryPeer,
      );

      expect(await harness.db.listPendingBackupRelay(limit: 10), isEmpty);
    });

    test('reconcilePendingBackupRelayAfterPull discards superseded queue rows', () async {
      final harness = await SyncP2pTestHarness.create(localRole: DeviceRole.backup);
      addTearDown(harness.dispose);

      const messageId = 'msg-reconcile';
      const newerMs = 8000;
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

      expect(
        await SyncEngine.instance.isEventSupersededByLocalState(staleEvent),
        isTrue,
      );

      await SyncProtocolService.instance.reconcilePendingBackupRelayAfterPull();
      expect(await harness.db.listPendingBackupRelay(limit: 10), isEmpty);
    });
  });
}

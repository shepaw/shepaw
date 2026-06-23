import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
import 'package:shepaw/identity/services/device_rpc_service.dart';
import 'package:shepaw/identity/services/sync_engine.dart';
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
        return Directory.systemTemp.createTempSync('shepaw_p1_fixes_test').path;
      }
      return null;
    });
  });

  group('P1 sync query origin', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      final accountId = 'p1-query-${DateTime.now().microsecondsSinceEpoch}';
      await db.switchAccount(accountId);
      await db.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 3));
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
      await AccountIdentityService.instance.activateAccountScopeForTests(accountId);
    });

    tearDown(() async {
      AccountIdentityService.instance.resetIdentityStateForTests();
      await db.close();
    });

    test('queryMessageEvents preserves stored origin, not local Primary', () async {
      const messageId = 'msg-query-origin';
      const iso = '2026-06-01T12:00:00.000';
      await db.upsertMessageFromSync({
        'id': messageId,
        'channel_id': 'ch-1',
        'sender_id': SyncP2pTestIds.appDevice,
        'sender_name': 'App',
        'content': 'stored message',
        'created_at': iso,
        'updated_at': iso,
      });

      final commitEvent = SyncEvent.messageEvent(
        messageRow: {
          'id': messageId,
          'channel_id': 'ch-1',
          'sender_id': SyncP2pTestIds.appDevice,
          'sender_name': 'App',
          'content': 'stored message',
          'created_at': iso,
          'updated_at': iso,
        },
        originDeviceId: SyncP2pTestIds.appDevice,
      );
      await SyncEngine.instance.recordEntitySyncState(commitEvent);

      final page = await SyncEngine.instance.queryMessageEvents(sinceMs: 0);
      expect(page.events, isNotEmpty);
      expect(page.events.first.originDeviceId, SyncP2pTestIds.appDevice);
      expect(page.events.first.originDeviceId, isNot(SyncP2pTestIds.primaryDevice));
    });
  });

  group('P1 agents.fetch RPC', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      final accountId = 'p1-rpc-${DateTime.now().microsecondsSinceEpoch}';
      await db.switchAccount(accountId);
      await db.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 5));
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
      await AccountIdentityService.instance.activateAccountScopeForTests(accountId);

      await db.upsertAgentFromSync(
        {
          'id': 'agent-secret',
          'name': 'Secret Bot',
          'token': 'super-secret-token',
          'endpoint': 'https://example.com',
          'protocol': 'a2a',
          'connection_type': 'http',
          'updated_at': 5000,
          'created_at': 4000,
        },
        persistToken: true,
      );
    });

    tearDown(() async {
      AccountIdentityService.instance.resetIdentityStateForTests();
      await db.close();
    });

    test('agents.fetch redacts token from response', () async {
      final resp = await DeviceRpcService.instance.handleInbound(
        method: 'agents.fetch',
        params: {'agent_id': 'agent-secret'},
      );
      expect(resp['error'], isNull);
      final agent = resp['agent'] as Map<String, dynamic>;
      expect(agent['name'], 'Secret Bot');
      expect(agent['token'], '');
    });
  });
}

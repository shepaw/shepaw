import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/models/sync_event.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
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
        return Directory.systemTemp.createTempSync('shepaw_agent_sync_test').path;
      }
      return null;
    });
  });

  group('agent sync secrets', () {
    late LocalDatabaseService db;

    setUp(() async {
      db = LocalDatabaseService();
      await db.close();
      final accountId = 'agent-sync-${DateTime.now().microsecondsSinceEpoch}';
      await db.switchAccount(accountId);
      await db.database;

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 4));
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

    test('App role applyAgentEvents does not persist remote token', () async {
      const agentId = 'remote-agent-1';
      final event = SyncEvent.agentEvent(
        agentRow: {
          'id': agentId,
          'name': 'Remote Bot',
          'token': 'secret-token-should-not-land-on-app',
          'endpoint': 'https://example.com',
          'protocol': 'a2a',
          'connection_type': 'http',
          'updated_at': 5000,
          'created_at': 4000,
        },
        originDeviceId: SyncP2pTestIds.primaryDevice,
      );

      await SyncEngine.instance.applyAgentEvents([event]);

      final row = await db.getAgentRowById(agentId);
      expect(row, isNotNull);
      expect(row!['token'], '');
    });
  });
}

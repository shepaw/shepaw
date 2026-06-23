import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/crypto/ed25519_identity.dart';
import 'package:shepaw/identity/models/device_role.dart';
import 'package:shepaw/identity/models/owned_device_record.dart';
import 'package:shepaw/identity/services/account_identity_service.dart';
import 'package:shepaw/identity/services/device_trust_service.dart';
import 'package:shepaw/identity/services/sync_protocol_service.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';
import 'package:shepaw/services/local_database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/sync_p2p_test_harness.dart';

Future<({
  LocalDatabaseService db,
  Ed25519Identity user,
  Ed25519Identity pet,
  String accountId,
})> _seedTrustTestAccount() async {
  final db = LocalDatabaseService();
  await db.close();
  final accountId = 'p0-trust-${DateTime.now().microsecondsSinceEpoch}';
  await db.switchAccount(accountId);
  await db.database;

  final user = Ed25519Identity.fromRawBytes(
    publicKey: Uint8List.fromList(List.generate(32, (i) => i + 1)),
    privateKey: Uint8List.fromList(List.generate(32, (i) => i + 10)),
  );
  final pet = Ed25519Identity.fromRawBytes(
    publicKey: Uint8List.fromList(List.generate(32, (i) => i + 50)),
    privateKey: Uint8List.fromList(List.generate(32, (i) => i + 60)),
  );
  final now = DateTime.now().millisecondsSinceEpoch;
  final key = Uint8List.fromList(List.filled(32, 3));

  await db.upsertIdentityUser(
    id: user.fingerprintHex,
    displayName: 'Test',
    publicKey: user.publicKey,
    createdAt: now,
  );
  await db.upsertSpiritPet(
    id: pet.fingerprintHex,
    userId: user.fingerprintHex,
    name: 'She',
    publicKey: pet.publicKey,
    agentId: 'agent-test',
    createdAt: now,
  );
  await db.upsertOwnedDevice(
    OwnedDeviceRecord(
      id: 'rec-local',
      deviceId: SyncP2pTestIds.primaryDevice,
      deviceName: 'Primary',
      role: DeviceRole.primary,
      transportPublicKey: key,
      fingerprint: 'fp-primary',
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      isLocal: true,
      trustedAt: now,
      lastSeenAt: now,
    ),
  );
  await db.upsertOwnedDevice(
    OwnedDeviceRecord(
      id: 'rec-backup',
      deviceId: SyncP2pTestIds.backupDevice,
      deviceName: 'Backup',
      role: DeviceRole.backup,
      transportPublicKey: key,
      fingerprint: 'fp-backup',
      userId: user.fingerprintHex,
      petId: pet.fingerprintHex,
      isLocal: false,
      trustedAt: now,
      lastSeenAt: now,
    ),
  );

  PeerStorageService().resetTablesReadyForTests();
  await PeerStorageService().ensureTables();
  await PeerStorageService().savePeer(
    PairedPeer(
      id: SyncP2pTestIds.backupPeer,
      deviceName: SyncP2pTestIds.backupDevice,
      deviceId: SyncP2pTestIds.backupDevice,
      publicKey: key,
      fingerprint: 'fp-backup',
      pairedAt: now,
    ),
  );

  await AccountIdentityService.instance.seedTestScopeForTests(
    accountId: accountId,
    user: user,
    pet: pet,
  );

  return (db: db, user: user, pet: pet, accountId: accountId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return Directory.systemTemp.createTempSync('shepaw_p0_test').path;
      }
      return null;
    });
  });

  group('P0 trust_accept role preservation', () {
    late LocalDatabaseService db;

    setUp(() async {
      final seeded = await _seedTrustTestAccount();
      db = seeded.db;
      SyncProtocolService.instance.stop();
      SyncProtocolService.instance.start();
    });

    tearDown(() async {
      SyncProtocolService.instance.stop();
      AccountIdentityService.instance.resetIdentityStateForTests();
      await db.close();
    });

    test('legacy trust_accept without role preserves backup role', () async {
      final user = await AccountIdentityService.instance.userIdentity();

      await SyncProtocolService.instance.dispatchControlForTest(
        SyncP2pTestIds.backupPeer,
        {
          'type': 'sync_trust_accept',
          'user_id': user.fingerprintHex,
          'device_id': SyncP2pTestIds.backupDevice,
          'device_name': 'Backup',
          'transport_public_key': base64.encode(List.filled(32, 8)),
          'transport_fingerprint': 'fp-backup-new',
        },
      );

      final backup = await db.getOwnedDeviceByDeviceId(SyncP2pTestIds.backupDevice);
      expect(backup?.role, DeviceRole.backup);
    });

    test('registerTrustedRemoteDevice with null role preserves existing', () async {
      await DeviceTrustService.instance.registerTrustedRemoteDevice(
        deviceId: SyncP2pTestIds.backupDevice,
        deviceName: 'Backup Updated',
        transportPublicKey: Uint8List.fromList(List.filled(32, 9)),
        fingerprint: 'fp-backup-new',
        role: null,
      );

      final backup = await db.getOwnedDeviceByDeviceId(SyncP2pTestIds.backupDevice);
      expect(backup?.role, DeviceRole.backup);
      expect(backup?.deviceName, 'Backup Updated');
    });
  });

  group('P0 sync_query canonical primary', () {
    late SyncP2pTestHarness harness;

    tearDown(() async {
      await harness.dispose();
    });

    test('non-canonical primary rejects sync_query', () async {
      harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.primary,
        localDeviceId: SyncP2pTestIds.primaryDevice,
        localPeerId: SyncP2pTestIds.primaryPeer,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      final key = Uint8List.fromList(List.filled(32, 5));
      await harness.db.upsertOwnedDevice(
        OwnedDeviceRecord(
          id: 'rec-backup-split',
          deviceId: SyncP2pTestIds.backupDevice,
          deviceName: 'Backup',
          role: DeviceRole.primary,
          transportPublicKey: key,
          fingerprint: 'fp-backup',
          userId: SyncP2pTestIds.userId,
          petId: SyncP2pTestIds.petId,
          isLocal: false,
          trustedAt: now,
          lastSeenAt: now,
        ),
      );

      harness.router.noteSender(SyncP2pTestIds.appPeer);
      await SyncProtocolService.instance.dispatchControlForTest(
        SyncP2pTestIds.appPeer,
        {
          'type': 'sync_query',
          'request_id': 'q-split-1',
          'since_ms': 0,
          'domain': 'message',
        },
      );

      final resp = harness.router.lastSentTo(SyncP2pTestIds.appPeer)?.payload;
      expect(resp?['error'], 'not_canonical_primary');
      expect(resp?['events'], isEmpty);
    });
  });

  group('P0 elected primary write restriction', () {
    late SyncP2pTestHarness harness;
    late Ed25519Identity user;
    late Ed25519Identity pet;

    tearDown(() async {
      await harness.dispose();
    });

    Future<void> seedHarnessIdentities() async {
      user = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i + 2)),
        privateKey: Uint8List.fromList(List.generate(32, (i) => i + 20)),
      );
      pet = Ed25519Identity.fromRawBytes(
        publicKey: Uint8List.fromList(List.generate(32, (i) => i + 70)),
        privateKey: Uint8List.fromList(List.generate(32, (i) => i + 80)),
      );
      await AccountIdentityService.instance.seedTestScopeForTests(
        accountId: harness.accountId,
        user: user,
        pet: pet,
      );
    }

    test('app role_announce cannot forge elected primary', () async {
      harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.primary,
        localDeviceId: SyncP2pTestIds.primaryDevice,
        localPeerId: SyncP2pTestIds.primaryPeer,
      );
      await seedHarnessIdentities();

      await harness.db.setIdentitySyncState(
        'user_elected_primary_device_id',
        SyncP2pTestIds.primaryDevice,
      );

      await SyncProtocolService.instance.dispatchControlForTest(
        SyncP2pTestIds.appPeer,
        {
          'type': 'sync_role_announce',
          'device_id': SyncP2pTestIds.appDevice,
          'device_name': 'App',
          'role': DeviceRole.app.wireValue,
          'user_id': user.fingerprintHex,
          'pet_id': pet.fingerprintHex,
          'elected_primary_device_id': SyncP2pTestIds.appDevice,
        },
      );

      expect(
        await AccountIdentityService.instance.userElectedPrimaryDeviceId(),
        SyncP2pTestIds.primaryDevice,
      );
    });

    test('primary role_announce may update elected primary', () async {
      harness = await SyncP2pTestHarness.create(
        localRole: DeviceRole.primary,
        localDeviceId: SyncP2pTestIds.primaryDevice,
        localPeerId: SyncP2pTestIds.primaryPeer,
      );
      await seedHarnessIdentities();

      await SyncProtocolService.instance.dispatchControlForTest(
        SyncP2pTestIds.primaryPeer,
        {
          'type': 'sync_role_announce',
          'device_id': SyncP2pTestIds.primaryDevice,
          'device_name': 'Primary',
          'role': DeviceRole.primary.wireValue,
          'user_id': user.fingerprintHex,
          'pet_id': pet.fingerprintHex,
          'elected_primary_device_id': SyncP2pTestIds.primaryDevice,
        },
      );

      expect(
        await AccountIdentityService.instance.userElectedPrimaryDeviceId(),
        SyncP2pTestIds.primaryDevice,
      );
    });
  });
}

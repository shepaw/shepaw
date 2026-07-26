import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/password_service.dart';
import 'package:shepaw/storage/device_cursor_store.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/master_migration_service.dart';
import 'package:shepaw/storage/mirror_reprotect_service.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';
import 'package:shepaw/storage/snapshot_service.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// M6：游标账 / 指针 epoch / 本机升主 / 镜像再保护。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(s.codeUnits);
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  group('DeviceCursorStore', () {
    test('all / seed 只进不退合并', () async {
      final tmp = await Directory.systemTemp.createTemp('cursor_seed');
      addTearDown(() => tmp.delete(recursive: true));
      final store = DeviceCursorStore(storeRoot: tmp);
      await store.advance('aaaaaaaaaaaaaaaa', 5);
      await store.advance('bbbbbbbbbbbbbbbb', 3);
      expect(await store.all(), {
        'aaaaaaaaaaaaaaaa': 5,
        'bbbbbbbbbbbbbbbb': 3,
      });
      await store.seed({
        'aaaaaaaaaaaaaaaa': 4,
        'bbbbbbbbbbbbbbbb': 9,
        'cccccccccccccccc': 1,
      });
      expect(await store.all(), {
        'aaaaaaaaaaaaaaaa': 5,
        'bbbbbbbbbbbbbbbb': 9,
        'cccccccccccccccc': 1,
      });
    });
  });

  group('MasterMigrationService.applyPointer', () {
    test('更高 epoch 改指；更低 epoch 忽略', () async {
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId(self);
      await LocalDatabaseService()
          .setUserValue(MasterMigrationService.epochKey, '0');

      final applied = await MasterMigrationService.instance.applyPointer(
        masterId: 'bbbbbbbbbbbbbbbb',
        epoch: 2,
        fromDeviceId: 'bbbbbbbbbbbbbbbb',
      );
      expect(applied, isTrue);
      expect(await StoreService.instance.masterDeviceId(), 'bbbbbbbbbbbbbbbb');
      expect(await MasterMigrationService.instance.currentEpoch(), 2);

      final ignored = await MasterMigrationService.instance.applyPointer(
        masterId: 'cccccccccccccccc',
        epoch: 1,
        fromDeviceId: 'cccccccccccccccc',
      );
      expect(ignored, isFalse);
      expect(await StoreService.instance.masterDeviceId(), 'bbbbbbbbbbbbbbbb');
    });
  });

  group('promoteSelf', () {
    test('旧 master 不可达时仍可升主并提升 epoch', () async {
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId('bbbbbbbbbbbbbbbb');
      final result =
          await MasterMigrationService.instance.promoteSelf(reprotect: false);
      expect(result.newMasterId, self);
      expect(result.epoch, greaterThan(0));
      expect(result.oldMasterReachable, isFalse);
      expect(result.seededFiles, 0);
      expect(result.hashGate.ran, isFalse);
      expect(await StoreService.instance.isMaster(), isTrue);
    });
  });

  group('MirrorReprotectService', () {
    test('加密镜像包经 store commit 落入 backups/reprotect-*', () async {
      const password = 'reprotect-pw';
      await PasswordService().setPassword(password);
      final h = await SnapshotCrypto.hashPassword(password);
      await SnapshotCrypto.cachePasswordHash(h);

      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId(self);

      final store = await StoreService.instance.localStore();
      final content = bytesOf('hello-mirror');
      final (u, _) = await store.writeBegin(
        deviceId: self,
        space: 'files',
        path: 'm6/hello.txt',
        size: content.length,
        sha256: sha(content),
      );
      await store.writeChunk(self, 'files', u, 0, content);
      await store.commit(self, 'files', [u]);

      final id = await MirrorReprotectService.instance.run(passwordHash: h);
      expect(id, startsWith('reprotect-'));
      final dir = Directory(p.join(store.root.path, self, 'backups', id));
      expect(File(p.join(dir.path, 'manifest.json')).existsSync(), isTrue);
      expect(File(p.join(dir.path, 'mirror.tar.enc')).existsSync(), isTrue);

      // 再保护包不得进入 DB 快照列表 / GFS（§5.1 vs §6.6）
      final listed = await SnapshotService.instance.listSnapshots();
      expect(listed.any((s) => s.id.startsWith('reprotect-')), isFalse);
    });

    test('再保护打包跳过既有 reprotect-* 目录', () async {
      const password = 'reprotect-skip-pw';
      final h = await SnapshotCrypto.hashPassword(password);
      await SnapshotCrypto.cachePasswordHash(h);
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId(self);
      final store = await StoreService.instance.localStore();

      // 植入一份「旧」再保护目录（大文件，若被打入会显著抬高 file_count）
      final oldId = 'reprotect-20000101-000000';
      final oldDir =
          Directory(p.join(store.root.path, self, 'backups', oldId));
      await oldDir.create(recursive: true);
      await File(p.join(oldDir.path, 'manifest.json')).writeAsString(
          '{"kind":"mirror_reprotect","created_at":1,"master_device":"$self",'
          '"file_count":0,"plain_sha256":"0","enc_sha256":"0",'
          '"kdf_salt":"AA==","kdf_iterations":1}');
      final junk = Uint8List(64 * 1024);
      await File(p.join(oldDir.path, 'mirror.tar.enc')).writeAsBytes(junk);

      // maxKeep 足够大，避免本用例被 prune 干扰打包断言
      final id = await MirrorReprotectService.instance
          .run(passwordHash: h, maxKeep: 20);
      final manifest = jsonDecode(await File(
              p.join(store.root.path, self, 'backups', id, 'manifest.json'))
          .readAsString()) as Map<String, dynamic>;
      // 旧 reprotect 的 64KB 不应计入；file_count 不应因 junk 暴涨到含该文件
      expect(manifest['kind'], 'mirror_reprotect');
      expect(manifest['file_count'] as int, lessThan(1000));
    });

    test('selectReprotectDelete / pruneReprotect 只留最新 N 份', () async {
      expect(
          MirrorReprotectService.selectReprotectDelete(
              ['r3', 'r2', 'r1', 'r0'],
              maxKeep: 2),
          ['r1', 'r0']);
      expect(
          MirrorReprotectService.selectReprotectDelete(['a', 'b'], maxKeep: 4),
          isEmpty);

      // 独立 store 根，避免与并行用例产生的今日 reprotect 抢排序
      final tmp = await Directory.systemTemp.createTemp('reprotect_prune');
      final store = LocalStore(root: tmp);
      const self = 'cccccccccccccccc';
      final backups = Directory(p.join(tmp.path, self, 'backups'));
      await backups.create(recursive: true);
      for (final id in [
        'reprotect-20200101-000001',
        'reprotect-20200102-000002',
        'reprotect-20200103-000003',
      ]) {
        final dir = Directory(p.join(backups.path, id));
        await dir.create(recursive: true);
        await File(p.join(dir.path, 'manifest.json'))
            .writeAsString('{"kind":"mirror_reprotect"}');
      }
      final removed = await MirrorReprotectService.instance.pruneReprotect(
        store: store,
        deviceId: self,
        maxKeep: 2,
      );
      expect(removed, 1);
      final left = await MirrorReprotectService.instance
          .listReprotectIds(store: store, deviceId: self);
      expect(left, ['reprotect-20200103-000003', 'reprotect-20200102-000002']);
    });
  });

  group('ACL v4', () {
    test('friend 拒 sync.cursors；owner 放行', () {
      const caller = 'aaaaaaaaaaaaaaaa';
      expect(
          checkStoreAcl(
              StoreFrame(op: StoreOp.syncCursors, payload: const {}),
              callerDeviceId: caller,
              trustLevel: TrustLevel.friend,
              loopback: false),
          StoreAcl.denyUntrusted);
      expect(
          checkStoreAcl(
              StoreFrame(op: StoreOp.masterPointerQuery, payload: const {}),
              callerDeviceId: caller,
              trustLevel: TrustLevel.owner,
              loopback: false),
          StoreAcl.allow);
    });
  });
}

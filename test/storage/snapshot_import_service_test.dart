import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/password_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/restore_service.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';
import 'package:shepaw/storage/snapshot_import_service.dart';
import 'package:shepaw/storage/snapshot_service.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// 换机快照下载：路径剥前缀（防嵌套）+ 恢复不污染密码缓存。
void main() {
  const password = 'import-pw';

  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
    await PasswordService().setPassword(password);
    await StoreService.instance.start();
  });

  test('stripSnapshotPrefix：含前缀 / 恰好等于 / 无前缀', () {
    expect(
        SnapshotImportService.stripSnapshotPrefix(
            '20260726-120000/manifest.json', '20260726-120000'),
        'manifest.json');
    expect(
        SnapshotImportService.stripSnapshotPrefix(
            '20260726-120000', '20260726-120000'),
        '');
    expect(
        SnapshotImportService.stripSnapshotPrefix(
            'manifest.json', '20260726-120000'),
        'manifest.json');
  });

  test('downloadSnapshot 剥掉 space 根前缀，文件落在 backups/<id>/ 单层', () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    final self = await DeviceIdentity.deviceId();

    final imported = await SnapshotImportService.instance.downloadSnapshot(
      serverDeviceId: self,
      oldDeviceId: self,
      snapshotId: info.id,
      grantId: 'ig-unused-loopback',
    );

    // 本机已有同名 → 落 -import 后缀，且文件不在嵌套目录
    expect(imported.id, '${info.id}-import');
    expect(File(p.join(imported.path, 'manifest.json')).existsSync(), isTrue);
    expect(File(p.join(imported.path, 'db.sqlite.enc')).existsSync(), isTrue);
    expect(File(p.join(imported.path, 'identity.enc')).existsSync(), isTrue);
    expect(Directory(p.join(imported.path, info.id)).existsSync(), isFalse,
        reason: '不得嵌套 backups/<id>/<id>/');
    expect(imported.manifest.kdfSalt, isNotNull);
    expect(imported.manifest.deviceId, self);
  });

  test('用旧密码恢复不污染当前自动快照密钥缓存', () async {
    const currentPw = 'current-master';
    const oldPw = 'old-master';
    await PasswordService().setPassword(currentPw);
    final currentH = await SnapshotCrypto.hashPassword(currentPw);
    await SnapshotCrypto.cachePasswordHash(currentH);

    // 造一份旧密码加密的快照（不刷新缓存）
    final oldSnap = await SnapshotService.instance
        .createSnapshot(password: oldPw, cachePassword: false);
    expect(await SnapshotCrypto.cachedPasswordHash(), equals(currentH));

    final preview =
        await RestoreService.instance.prepareRestore(oldSnap, oldPw);
    await RestoreService.instance.executeRestore(preview, oldPw);

    expect(await SnapshotCrypto.cachedPasswordHash(), equals(currentH),
        reason: '恢复用旧密码不得覆盖当前主密码缓存 H');
  });
}

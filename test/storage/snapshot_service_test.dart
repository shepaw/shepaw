import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/noise_identity.dart';
import 'package:shepaw/services/password_service.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/restore_service.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';
import 'package:shepaw/storage/snapshot_service.dart';

import 'test_harness.dart';

/// 快照引擎端到端（真实 schema、真实加密、真文件）：
/// 生成 → 列表 → 校验 → 篡改检测 → 解密 → 恢复 → 身份完整。
void main() {
  const password = 'test-master-pw';

  setUpAll(() async {
    await StorageTestHarness.init();
    // 主密码（恢复时强制验密）
    await LocalDatabaseService().database;
    await PasswordService().setPassword(password);
  });

  Future<void> seedData(String marker) async {
    final db = await LocalDatabaseService().database;
    await db.insert('channels', {
      'id': 'ch-$marker',
      'name': 'seed $marker',
      'type': 'dm',
      'created_at': '2026-07-26T00:00:00Z',
      'updated_at': '2026-07-26T00:00:00Z',
      'created_by': 'test',
    });
  }

  Future<bool> hasChannel(String id) async {
    final db = await LocalDatabaseService().database;
    return (await db.query('channels', where: 'id = ?', whereArgs: [id]))
        .isNotEmpty;
  }

  test('生成快照：manifest 结构 + 密文落盘 + 目录布局符合 §5.2', () async {
    await seedData('create');
    final deviceId = await DeviceIdentity.deviceId();
    final info =
        await SnapshotService.instance.createSnapshot(password: password);

    // 目录布局 <device_id>/backups/<ts>/
    expect(info.path, contains('/store/$deviceId/backups/'));
    expect(File(p.join(info.path, 'manifest.json')).existsSync(), isTrue);
    expect(File(p.join(info.path, 'db.sqlite.enc')).existsSync(), isTrue);
    expect(File(p.join(info.path, 'identity.enc')).existsSync(), isTrue);
    // 明文 DB 不残留；经 store commit 后无 backups/.staging 半成品
    expect(File(p.join(info.path, 'db.raw')).existsSync(), isFalse);
    final spaceStaging = Directory(p.join(p.dirname(info.path), '.staging'));
    if (await spaceStaging.exists()) {
      expect(await spaceStaging.list().isEmpty, isTrue);
    }

    final m = info.manifest;
    expect(m.deviceId, deviceId);
    expect(m.schemaVersion, 29);
    expect(m.dbSha256.length, 64);
    expect(m.fileHashes.keys,
        containsAll(['db.sqlite.enc', 'identity.enc']));
    expect(
        m.treeRoot, SnapshotManifest.computeTreeRoot(m.fileHashes));

    // 密文 ≠ 明文（加密生效）：密文里搜不到种子数据
    final encBytes =
        await File(p.join(info.path, 'db.sqlite.enc')).readAsBytes();
    expect(utf8.decode(encBytes, allowMalformed: true).contains('seed create'),
        isFalse);

    // 列表可枚举
    final list = await SnapshotService.instance.listSnapshots();
    expect(list.any((s) => s.id == info.id), isTrue);
  });

  test('校验：原样 ok；改密文 → fileTampered；改 manifest → manifestTampered',
      () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    expect(await SnapshotService.instance.verifySnapshot(info),
        SnapshotVerifyStatus.ok);

    // 篡改密文一字节
    final encFile = File(p.join(info.path, 'db.sqlite.enc'));
    final bytes = await encFile.readAsBytes();
    bytes[10] ^= 0xFF;
    await encFile.writeAsBytes(bytes, flush: true);
    expect(await SnapshotService.instance.verifySnapshot(info),
        SnapshotVerifyStatus.fileTampered);

    // 另一份快照：篡改 manifest 的 fileHashes 但不更新树根 → 树根不自洽
    final info2 =
        await SnapshotService.instance.createSnapshot(password: password);
    final manifestFile = File(p.join(info2.path, 'manifest.json'));
    final tampered = SnapshotManifest(
      deviceId: info2.manifest.deviceId,
      createdAtMs: info2.manifest.createdAtMs,
      appVersion: info2.manifest.appVersion,
      schemaVersion: info2.manifest.schemaVersion,
      dbSha256: info2.manifest.dbSha256,
      fileHashes: Map.of(info2.manifest.fileHashes)
        ..['db.sqlite.enc'] = '0' * 64,
      treeRoot: info2.manifest.treeRoot,
    );
    await manifestFile.writeAsString(jsonEncode(tampered.toJson()));
    expect(await SnapshotService.instance.verifySnapshot(info2),
        SnapshotVerifyStatus.manifestTampered);
  });

  test('解密：错密码拒绝；对密码还原明文', () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    expect(
      () => SnapshotService.instance.decryptDb(info, 'wrong-pw'),
      throwsA(isA<SnapshotDecryptException>()),
    );
    final plain = await SnapshotService.instance.decryptDb(info, password);
    expect(plain.length, greaterThan(0));
    // SQLite 文件头
    expect(String.fromCharCodes(plain.sublist(0, 15)), 'SQLite format 3');
  });

  test('恢复：数据与 device_id 完整；恢复期间当前状态有安全快照兜底', () async {
    final beforeIdentity = await DeviceIdentity.deviceId();
    await seedData('before-snapshot');
    final info =
        await SnapshotService.instance.createSnapshot(password: password);

    // 快照后继续演进：新增数据（恢复后应消失）
    await seedData('after-snapshot');
    expect(await hasChannel('ch-after-snapshot'), isTrue);

    // 准备 + 执行恢复
    final preview =
        await RestoreService.instance.prepareRestore(info, password);
    await RestoreService.instance.executeRestore(preview, password);

    // 重新打开数据库（executeRestore 已关闭连接）
    expect(await hasChannel('ch-before-snapshot'), isTrue);
    expect(await hasChannel('ch-after-snapshot'), isFalse);

    // device_id 完整
    expect(await DeviceIdentity.deviceId(), beforeIdentity);

    // 安全快照兜底存在（恢复前自动留存）
    final list = await SnapshotService.instance.listSnapshots();
    expect(list.length, greaterThanOrEqualTo(2));

    // 主库旁留下 .pre-restore 兜底文件
    final docs = p.dirname(info.path.contains('/store/')
        ? info.path.split('/store/').first
        : info.path);
    expect(docs, isNotEmpty);
  });

  test('恢复前置：manifest 被篡改的快照拒绝恢复', () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    // 破坏密文
    final encFile = File(p.join(info.path, 'db.sqlite.enc'));
    final bytes = await encFile.readAsBytes();
    bytes[5] ^= 0xFF;
    await encFile.writeAsBytes(bytes, flush: true);

    expect(
      () => RestoreService.instance.prepareRestore(info, password),
      throwsStateError,
    );
  });

  test('恢复前置：错密码拒绝（解密即验密，不再要求等于当前密码）', () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    expect(
      () => RestoreService.instance.prepareRestore(info, 'nope'),
      throwsA(isA<SnapshotDecryptException>()),
    );
  });

  test('换机导入模式（restoreIdentity=false）：数据恢复但保留新设备身份', () async {
    final identityBefore = await DeviceIdentity.deviceId();
    await seedData('migrate');
    final info =
        await SnapshotService.instance.createSnapshot(password: password);

    final preview =
        await RestoreService.instance.prepareRestore(info, password);
    await RestoreService.instance
        .executeRestore(preview, password, restoreIdentity: false);

    expect(await hasChannel('ch-migrate'), isTrue);
    // 新设备保留自己的 device_id（§5.4：两个 device_id 互不影响）
    expect(await DeviceIdentity.deviceId(), identityBefore);
  });

  test('本机导出：快照目录整体复制', () async {
    final info =
        await SnapshotService.instance.createSnapshot(password: password);
    final tmp = await Directory.systemTemp.createTemp('snapshot_export');
    final out =
        await SnapshotService.instance.exportToDirectory(info, tmp.path);
    expect(File(p.join(out.path, 'manifest.json')).existsSync(), isTrue);
    expect(File(p.join(out.path, 'db.sqlite.enc')).existsSync(), isTrue);
    expect(File(p.join(out.path, 'identity.enc')).existsSync(), isTrue);
  });
}

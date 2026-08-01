import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/folder_binding_service.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  late Directory external;

  setUpAll(() async {
    await StorageTestHarness.init();
  });

  setUp(() async {
    external = await Directory.systemTemp.createTemp('binding_ext');
  });

  tearDown(() async {
    if (await external.exists()) await external.delete(recursive: true);
  });

  Future<String> deviceId() => DeviceIdentity.deviceId();

  Future<File> storeFile(String rel) async {
    final root = await StoreService.instance.storeRoot();
    final device = await deviceId();
    return File(p.join(root.path, device, 'files', rel));
  }

  test('绑定摄取：新增 / 修改 / 忽略 / 删除', () async {
    final svc = FolderBindingService.instance;
    final binding = await svc.add(
      label: 'inbox',
      external: external.path,
      space: 'files',
      folder: 'inbox',
      ignore: ['*.tmp', '.DS_Store'],
    );

    // 新增
    File(p.join(external.path, 'a.txt')).writeAsStringSync('one');
    File(p.join(external.path, 'x.tmp')).writeAsStringSync('skip me');
    final r1 = await svc.syncOne(binding);
    expect(r1.added, 1, reason: 'ignored *.tmp must not be ingested');
    expect(r1.errors, isEmpty);
    expect(await (await storeFile('inbox/a.txt')).readAsString(), 'one');
    expect(await (await storeFile('inbox/x.tmp')).exists(), isFalse);

    // 修改
    File(p.join(external.path, 'a.txt')).writeAsStringSync('two');
    final r2 = await svc.syncOne(binding);
    expect(r2.updated, 1);
    expect(await (await storeFile('inbox/a.txt')).readAsString(), 'two');

    // 无变化 → skipped
    final r3 = await svc.syncOne(binding);
    expect(r3.skipped, 1);
    expect(r3.added + r3.updated + r3.deleted, 0);

    // 删除 → 进回收站
    File(p.join(external.path, 'a.txt')).deleteSync();
    final r4 = await svc.syncOne(binding);
    expect(r4.deleted, 1);
    expect(await (await storeFile('inbox/a.txt')).exists(), isFalse);
    final root = await StoreService.instance.storeRoot();
    final recycled = Directory(p.join(root.path, '.recycle'));
    expect(await recycled.exists(), isTrue);
  });

  test('绑定列表持久化 + 外部目录缺失报告', () async {
    final svc = FolderBindingService.instance;
    final binding = await svc.add(
      label: 'gone',
      external: external.path,
      space: 'files',
      folder: 'gone',
    );
    final listed = await svc.list();
    expect(listed.map((b) => b.id), contains(binding.id));

    await external.delete(recursive: true);
    final report = await svc.syncOne(binding);
    expect(report.errors, isNotEmpty);
    expect(report.errors.first, contains('external dir not found'));
  });
}

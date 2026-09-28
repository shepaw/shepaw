import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// 工作区挂载视图（docs/workspace_mount_decision.md A 档）。
///
/// 挂载点是外部真实目录的视图，不是副本：改磁盘即改袋，写与删一律拒绝。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('registry 解析覆盖关系与外部路径，拒绝越界', () async {
    final store = await StoreService.instance.localStore();
    final reg = store.mounts;
    final mount = await reg.add(
      space: 'workspaces',
      path: 'ext/proj',
      external: p.join(Directory.systemTemp.path, 'shepaw-mount-x'),
    );

    expect((await reg.covering('workspaces', 'ext/proj'))?.id, mount.id);
    expect(
        (await reg.covering('workspaces', 'ext/proj/src/a.txt'))?.id, mount.id);
    expect(await reg.covering('workspaces', 'ext/other'), isNull);
    expect(await reg.covering('files', 'ext/proj'), isNull);

    expect(reg.externalPath(mount, 'ext/proj/a.txt'),
        p.join(mount.external, 'a.txt'));
    // `..` 逃逸出挂载根
    expect(reg.externalPath(mount, 'ext/proj/../out.txt'), isNull);

    await reg.remove(mount.id);
    expect(await reg.covering('workspaces', 'ext/proj'), isNull);
  });

  test('挂载视图：列目录与读穿透到磁盘，写删拒绝', () async {
    final store = await StoreService.instance.localStore();
    final device = await DeviceIdentity.deviceId();
    final ext = await Directory.systemTemp.createTemp('shepaw-mount-view');
    final file = File(p.join(ext.path, 'a.txt'));
    await file.writeAsString('v1');

    final mount = await store.mounts.add(
      space: 'workspaces',
      path: 'ext/proj',
      external: ext.path,
    );

    // 挂载路径上的中间目录会出现在祖先列表里（袋里没有实体）
    final roots =
        await store.list(device, 'workspaces', depth: 1, computeHash: false);
    expect(roots.any((e) => e.path == 'ext' && e.isDir), isTrue);

    final mid = await store.list(device, 'workspaces',
        prefix: 'ext', depth: 1, computeHash: false);
    expect(mid.any((e) => e.path == 'ext/proj' && e.isDir), isTrue);

    // 列挂载点 = 列外部目录
    final inside = await store.list(device, 'workspaces',
        prefix: 'ext/proj', depth: 1, computeHash: false);
    expect([for (final e in inside) e.path], contains('ext/proj/a.txt'));

    // 读穿透
    Future<String> readMounted() async {
      final (bytes, _, _) =
          await store.read(device, 'workspaces', 'ext/proj/a.txt', 0, 64);
      return String.fromCharCodes(bytes);
    }

    expect(await readMounted(), 'v1');
    // 改磁盘即改袋（同一份，没有副本）
    await file.writeAsString('v2');
    expect(await readMounted(), 'v2');

    // 写与删都拒绝：挂载视图没有副本，动它就是动用户磁盘
    expect(
      () => store.writeBegin(
        deviceId: device,
        space: 'workspaces',
        path: 'ext/proj/b.txt',
        size: 1,
        sha256: 'a' * 64,
      ),
      throwsA(isA<StoreException>()),
    );
    expect(
      () => store.delete(device, 'workspaces', 'ext/proj/a.txt'),
      throwsA(isA<StoreException>()),
    );
    // 拒绝后磁盘文件仍在
    expect(await file.exists(), isTrue);

    await store.mounts.remove(mount.id);
    await ext.delete(recursive: true);
  });

  test('无挂载时行为不变：workspaces 列表为空', () async {
    final store = await StoreService.instance.localStore();
    final device = await DeviceIdentity.deviceId();
    final entries =
        await store.list(device, 'workspaces', depth: 1, computeHash: false);
    expect(entries, isEmpty);
  });
}

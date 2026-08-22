import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_export_service.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// 危险区：本机 store 树导出（方案 §7.5）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  test('exportSelfTree 复制四分区正式文件并跳过 staging', () async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final content = bytesOf('export-tree-payload');
    final (uid, _) = await store.writeBegin(
      deviceId: self,
      space: StoreSpace.artifacts,
      path: 't/hello.txt',
      size: content.length,
      sha256: sha(content),
    );
    await store.writeChunk(self, StoreSpace.artifacts, uid, 0, content);
    await store.commit(self, StoreSpace.artifacts, [uid]);

    // staging 半成品：不应进导出
    await store.writeBegin(
      deviceId: self,
      space: StoreSpace.files,
      path: 'draft.bin',
      size: 3,
      sha256: sha(bytesOf('abc')),
    );

    final outRoot = await Directory.systemTemp.createTemp('store_export');
    addTearDown(() => outRoot.delete(recursive: true));
    final result =
        await StoreExportService.instance.exportSelfTree(outRoot.path);

    expect(result.fileCount, greaterThanOrEqualTo(1));
    expect(result.totalBytes, greaterThanOrEqualTo(content.length));
    final exported = File(p.join(
        result.directory.path, StoreSpace.artifacts, 't', 'hello.txt'));
    expect(await exported.readAsBytes(), content);

    final stagingLeak = Directory(
        p.join(result.directory.path, StoreSpace.files, '.staging'));
    expect(await stagingLeak.exists(), isFalse);
    final draft = File(
        p.join(result.directory.path, StoreSpace.files, 'draft.bin'));
    expect(await draft.exists(), isFalse);
  });
}

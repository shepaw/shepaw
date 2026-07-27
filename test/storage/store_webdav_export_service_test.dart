import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/store_webdav_export_service.dart';
import 'package:shepaw/storage/webdav_uploader.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  test('exportSelfTree 上传正式文件并跳过 staging', () async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final content = bytesOf('webdav-payload');
    final (uid, _) = await store.writeBegin(
      deviceId: self,
      space: StoreSpace.files,
      path: 'docs/note.txt',
      size: content.length,
      sha256: sha(content),
    );
    await store.writeChunk(self, StoreSpace.files, uid, 0, content);
    await store.commit(self, StoreSpace.files, [uid]);

    await store.writeBegin(
      deviceId: self,
      space: StoreSpace.files,
      path: 'draft.bin',
      size: 3,
      sha256: sha(bytesOf('abc')),
    );

    final mem = MemoryWebdavUploader();
    final result = await StoreWebdavExportService.instance.exportSelfTree(
      uploader: mem,
      remotePrefix: 'exports',
    );

    expect(result.fileCount, greaterThanOrEqualTo(1));
    expect(result.totalBytes, greaterThanOrEqualTo(content.length));
    expect(result.remoteRoot, 'exports/$self');

    final remotePath = 'exports/$self/${StoreSpace.files}/docs/note.txt';
    expect(mem.files[remotePath], content);
    expect(
      mem.files.keys.any((k) => k.endsWith('draft.bin')),
      isFalse,
    );
    expect(mem.collections.contains('exports/$self/${StoreSpace.files}'),
        isTrue);

    // 本地 staging 仍在，但未上传
    final staging = Directory(
        p.join(store.root.path, self, StoreSpace.files, '.staging'));
    expect(await staging.exists(), isTrue);
  });

  test('MemoryWebdavUploader ensureCollection 分层创建', () async {
    final mem = MemoryWebdavUploader();
    await mem.ensureCollection('a/b/c');
    expect(mem.collections, containsAll(['a', 'a/b', 'a/b/c']));
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:shepaw/storage/store_uri_reader.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('StoreUriReader 可读 files 空间 URI', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList(utf8.encode('pouch note'));
    const relPath = 'docs/pouch-note.txt';
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.files, uploadId, 0, content);
    await store.commit(deviceId, StoreSpace.files, [uploadId]);

    final uri = storeUriWithRef(StoreSpace.files, deviceId, relPath);
    final back = await StoreUriReader.instance.read(uri);
    expect(utf8.decode(back), 'pouch note');
  });

  test('StoreUriReader.kindOf 区分文件与目录', () async {
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    final content = Uint8List.fromList(utf8.encode('kind check'));
    const relPath = 'docs/kind-check.txt';
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.files,
      path: relPath,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.files, uploadId, 0, content);
    await store.commit(deviceId, StoreSpace.files, [uploadId]);

    final fileUri = storeUriWithRef(StoreSpace.files, deviceId, relPath);
    final dirUri = storeUriWithRef(StoreSpace.files, deviceId, 'docs');
    final spaceUri = 'store://${StoreSpace.files}/$deviceId';
    expect(await StoreUriReader.instance.kindOf(fileUri), StoreUriKind.file);
    expect(
        await StoreUriReader.instance.kindOf(dirUri), StoreUriKind.directory);
    expect(
        await StoreUriReader.instance.kindOf(spaceUri), StoreUriKind.directory);

    const wsRel = 'Users/edenzou/workspace/shepaw/channel/cmd/note.txt';
    final (wsId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.workspaces,
      path: wsRel,
      size: content.length,
      sha256: crypto.sha256.convert(content).toString(),
    );
    await store.writeChunk(deviceId, StoreSpace.workspaces, wsId, 0, content);
    await store.commit(deviceId, StoreSpace.workspaces, [wsId]);
    final folderUri = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'Users/edenzou/workspace/shepaw/channel/cmd',
    );
    expect(
      await StoreUriReader.instance.kindOf(folderUri),
      StoreUriKind.directory,
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(folderUri),
      'Users/edenzou/workspace/shepaw/channel/cmd',
    );
    final missingLeaf = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'Users/edenzou/workspace/shepaw/channel/cmd/no-such-child',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(missingLeaf),
      'Users/edenzou/workspace/shepaw/channel/cmd/no-such-child',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(fileUri),
      'docs',
    );
    final ghost = storeUriWithRef(
      StoreSpace.workspaces,
      deviceId,
      'no/such/remote-folder',
    );
    expect(
      await StoreUriReader.instance.existingDirectoryPrefix(ghost),
      'no/such/remote-folder',
    );
  });

  test('StoreUriReader 拒绝他端私有分区', () async {
    const other = 'bbbbbbbbbbbbbbbb';
    final uri = storeUriWithRef(StoreSpace.attachments, other, 'deadbeef');
    expect(
      () => StoreUriReader.instance.read(uri),
      throwsA(isA<ArgumentError>()),
    );
  });
}

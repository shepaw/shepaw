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

  test('StoreUriReader 拒绝他端私有分区', () async {
    const other = 'bbbbbbbbbbbbbbbb';
    final uri = storeUriWithRef(StoreSpace.attachments, other, 'deadbeef');
    expect(
      () => StoreUriReader.instance.read(uri),
      throwsA(isA<ArgumentError>()),
    );
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/public_store_service.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  test('public writeText 落盘并返回 store URI', () async {
    final uri = await PublicStoreService.instance.writeText(
      relPath: 'notes/hello.md',
      content: '# hello public',
    );
    final deviceId = await DeviceIdentity.deviceId();
    expect(uri, 'store://public/$deviceId/notes/hello.md');

    final store = await StoreService.instance.localStore();
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.public_,
      'notes/hello.md',
      0,
      1 << 16,
    );
    expect(utf8.decode(bytes), contains('hello public'));
  });

  test('writeReferenceList 不复制字节', () async {
    final deviceId = await DeviceIdentity.deviceId();
    final filesUri = 'store://files/$deviceId/docs/a.txt';
    final listUri = await PublicStoreService.instance.writeReferenceList(
      listName: 'exports',
      storeUris: [filesUri, 'not-a-uri'],
      title: 'Exports',
    );
    expect(listUri, 'store://public/$deviceId/exports.md');
    final store = await StoreService.instance.localStore();
    final (bytes, _, _) = await store.read(
      deviceId,
      StoreSpace.public_,
      'exports.md',
      0,
      1 << 16,
    );
    final text = utf8.decode(bytes);
    expect(text, contains(filesUri));
    expect(text, isNot(contains('not-a-uri')));
  });
}

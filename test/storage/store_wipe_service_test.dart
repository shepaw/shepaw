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
import 'package:shepaw/storage/store_wipe_service.dart';
import 'package:shepaw/storage/sync_journal.dart';

import 'test_harness.dart';

/// 危险区：清空本机 store 树（方案 §7.5）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  test('wipeSelfTree 删本机文件、清队列、保留 change_seq', () async {
    final self = await DeviceIdentity.deviceId();
    final store = await StoreService.instance.localStore();
    final journal = SyncJournal(storeRoot: store.root, ownerDeviceId: self);
    LocalStore.syncJournal = journal;

    final content = bytesOf('wipe-payload');
    final (uid, _) = await store.writeBegin(
      deviceId: self,
      space: StoreSpace.files,
      path: 'gone.txt',
      size: content.length,
      sha256: sha(content),
    );
    await store.writeChunk(self, StoreSpace.files, uid, 0, content);
    await store.commit(self, StoreSpace.files, [uid]);

    final before = await journal.cursors();
    expect(before.changeSeq, greaterThan(0));
    expect(await journal.pendingCount(), greaterThan(0));

    final result = await StoreWipeService.instance.wipeSelfTree();
    expect(result.freedBytes, greaterThanOrEqualTo(content.length));
    expect(await store.list(self, StoreSpace.files), isEmpty);
    expect(await journal.pendingCount(), 0);
    final after = await journal.cursors();
    expect(after.changeSeq, before.changeSeq);
    expect(
      await File(p.join(store.root.path, self, StoreSpace.files, 'gone.txt'))
          .exists(),
      isFalse,
    );
  });
}

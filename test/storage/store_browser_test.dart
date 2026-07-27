import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

/// 文件浏览手删依赖的 LocalStore list/delete 路径（方案 §7.3）。
void main() {
  late Directory tmp;
  late LocalStore store;
  const self = 'aaaaaaaaaaaaaaaa';
  const other = 'bbbbbbbbbbbbbbbb';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('store_browser_test');
    store = LocalStore(root: tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<void> put(String device, String space, String path, String text) async {
    final c = bytesOf(text);
    final (u, _) = await store.writeBegin(
      deviceId: device,
      space: space,
      path: path,
      size: c.length,
      sha256: sha(c),
    );
    await store.writeChunk(device, space, u, 0, c);
    await store.commit(device, space, [u]);
  }

  test('按 prefix 列出并删除进回收站', () async {
    await put(self, StoreSpace.files, 'docs/a.txt', 'aaa');
    await put(self, StoreSpace.files, 'docs/b.txt', 'bbb');
    await put(self, StoreSpace.files, 'other/c.txt', 'ccc');
    await put(other, StoreSpace.files, 'peer.txt', 'peer');

    final listed = await store.list(self, StoreSpace.files, prefix: 'docs/');
    expect(listed.map((e) => e.path).toList(), ['docs/a.txt', 'docs/b.txt']);

    await store.delete(self, StoreSpace.files, 'docs/a.txt');
    expect(
      (await store.list(self, StoreSpace.files, prefix: 'docs/'))
          .map((e) => e.path),
      ['docs/b.txt'],
    );
    final recycle = await store.recycleList();
    expect(recycle, isNotEmpty);
    expect(
      recycle.any((e) =>
          e.originDevice == self &&
          (e.originPath == 'docs' || e.originPath.startsWith('docs/'))),
      isTrue,
    );

    // master 风格：删他端镜像
    await store.delete(other, StoreSpace.files, 'peer.txt');
    expect(await store.list(other, StoreSpace.files), isEmpty);
  });
}

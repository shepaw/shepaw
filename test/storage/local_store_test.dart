import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

/// LocalStore 文件系统实现（staging/commit/回收站/stats/gc）。
/// 临时目录直测，无插件依赖。
void main() {
  late Directory tmp;
  late LocalStore store;
  const dev = 'aaaaaaaaaaaaaaaa';
  const devB = 'bbbbbbbbbbbbbbbb';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('local_store_test');
    store = LocalStore(root: tmp);
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<(String, int)> begin(String path, Uint8List content,
          {String space = 'files', String? uploadId}) =>
      store.writeBegin(
          deviceId: dev,
          space: space,
          path: path,
          size: content.length,
          sha256: sha(content),
          uploadId: uploadId);

  group('staging/commit', () {
    test('半成品对 list 不可见；commit 后可见且哈希正确', () async {
      final content = bytesOf('hello store');
      final (uploadId, _) = await begin('a/b.txt', content);
      await store.writeChunk(dev, 'files', uploadId, 0, content);

      // 未 commit：list/meta 不可见
      expect(await store.list(dev, 'files'), isEmpty);

      final (committed, failed) =
          await store.commit(dev, 'files', [uploadId]);
      expect(committed, ['a/b.txt']);
      expect(failed, isEmpty);

      final list = await store.list(dev, 'files');
      expect(list.single.path, 'a/b.txt');
      expect(list.single.sha256, sha(content));
      expect(list.single.size, content.length);
    });

    test('哈希不符拒绝转正，staging 保留可重传', () async {
      final content = bytesOf('good');
      final (uploadId, _) = await begin('x.txt', content);
      // 写入与声明不符的内容
      await store.writeChunk(dev, 'files', uploadId, 0, bytesOf('BAD!'));

      final (committed, failed) =
          await store.commit(dev, 'files', [uploadId]);
      expect(committed, isEmpty);
      expect(failed.single, contains('hash mismatch'));
      expect(await store.list(dev, 'files'), isEmpty);

      // 重传正确内容后可转正（offset 幂等重写）
      await store.writeChunk(dev, 'files', uploadId, 0, content);
      final (c2, f2) = await store.commit(dev, 'files', [uploadId]);
      expect(c2, ['x.txt']);
      expect(f2, isEmpty);
    });

    test('断点续传：重复 write.begin 返回已接收量', () async {
      final content = bytesOf('0123456789abcdef');
      final (uploadId, _) = await begin('resume.txt', content);
      await store.writeChunk(
          dev, 'files', uploadId, 0, content.sublist(0, 6));

      final (id2, received) = await begin('resume.txt', content,
          uploadId: uploadId);
      expect(id2, uploadId);
      expect(received, 6);

      await store.writeChunk(
          dev, 'files', uploadId, 6, content.sublist(6));
      final (committed, _) = await store.commit(dev, 'files', [uploadId]);
      expect(committed, ['resume.txt']);
    });

    test('冲突的 upload_id（声明不同）报 staging_state', () async {
      final (uploadId, _) = await begin('a.txt', bytesOf('aaa'));
      expect(
        () => begin('b.txt', bytesOf('bbb'), uploadId: uploadId),
        throwsA(predicate((e) =>
            e is StoreException && e.code == StoreError.stagingState)),
      );
    });

    test('offset 越界拒绝', () async {
      final (uploadId, _) = await begin('y.txt', bytesOf('1234'));
      expect(
        () => store.writeChunk(dev, 'files', uploadId, 5, bytesOf('x')),
        throwsA(predicate((e) =>
            e is StoreException && e.code == StoreError.stagingState)),
      );
    });
  });

  group('read/meta', () {
    test('分块读取与 eof', () async {
      final content = Uint8List.fromList(
          List.generate(200 * 1024, (i) => i % 256));
      final (uploadId, _) = await begin('big.bin', content);
      await store.writeChunk(dev, 'files', uploadId, 0, content);
      await store.commit(dev, 'files', [uploadId]);

      final (c1, size1, eof1) =
          await store.read(dev, 'files', 'big.bin', 0, 65536);
      expect(c1.length, 65536);
      expect(size1, content.length);
      expect(eof1, isFalse);

      final (c2, _, eof2) =
          await store.read(dev, 'files', 'big.bin', 65536, 65536);
      expect(c2.length, 65536);
      expect(eof2, isFalse);

      final (c3, _, eof3) =
          await store.read(dev, 'files', 'big.bin', 131072, 65536);
      expect(c3.length, 65536);
      expect(eof3, isFalse);

      final (c4, _, eof4) =
          await store.read(dev, 'files', 'big.bin', 196608, 65536);
      expect(c4.length, content.length - 196608);
      expect(eof4, isTrue);

      expect(Uint8List.fromList([...c1, ...c2, ...c3, ...c4]), content);
    });

    test('meta：文件与目录清单', () async {
      final c = bytesOf('meta');
      final (u1, _) = await begin('d/f1.txt', c);
      await store.writeChunk(dev, 'files', u1, 0, c);
      final (u2, _) = await begin('d/f2.txt', c);
      await store.writeChunk(dev, 'files', u2, 0, c);
      await store.commit(dev, 'files', [u1, u2]);

      final fileMeta = await store.meta(dev, 'files', 'd/f1.txt');
      expect(fileMeta['kind'], 'file');
      expect(fileMeta['sha256'], sha(c));

      final dirMeta = await store.meta(dev, 'files', 'd');
      expect(dirMeta['kind'], 'dir');
      expect((dirMeta['files'] as List).length, 2);
    });
  });

  group('delete/recycle', () {
    test('删除进回收站；还原回 list', () async {
      final c = bytesOf('trash me');
      final (u, _) = await begin('t.txt', c);
      await store.writeChunk(dev, 'files', u, 0, c);
      await store.commit(dev, 'files', [u]);

      final recyclePath = await store.delete(dev, 'files', 't.txt');
      expect(recyclePath, startsWith('.recycle/'));
      expect(await store.list(dev, 'files'), isEmpty);

      final entries = await store.recycleList();
      expect(entries.single.originPath, 't.txt');
      expect(entries.single.originDevice, dev);
      expect(entries.single.space, 'files');

      final restored =
          await store.recycleRestore(entries.single.recyclePath);
      expect(restored, 't.txt');
      expect((await store.list(dev, 'files')).single.path, 't.txt');
      expect(await store.recycleList(), isEmpty);
    });

    test('覆盖写：旧版本进回收站', () async {
      final v1 = bytesOf('version one');
      final (u1, _) = await begin('o.txt', v1);
      await store.writeChunk(dev, 'files', u1, 0, v1);
      await store.commit(dev, 'files', [u1]);

      final v2 = bytesOf('version two!');
      final (u2, _) = await begin('o.txt', v2);
      await store.writeChunk(dev, 'files', u2, 0, v2);
      await store.commit(dev, 'files', [u2]);

      final recycle = await store.recycleList();
      expect(recycle.single.originPath, 'o.txt');
      // 回收站里的应是 v1
      final (data, _, __) = await store.read(dev, 'files', 'o.txt', 0, 64);
      expect(utf8.decode(data), 'version two!');
    });

    test('还原时原位置有文件：现有文件先回收入站', () async {
      final v1 = bytesOf('old');
      final (u1, _) = await begin('r.txt', v1);
      await store.writeChunk(dev, 'files', u1, 0, v1);
      await store.commit(dev, 'files', [u1]);
      final rp = await store.delete(dev, 'files', 'r.txt');

      final v2 = bytesOf('new!');
      final (u2, _) = await begin('r.txt', v2);
      await store.writeChunk(dev, 'files', u2, 0, v2);
      await store.commit(dev, 'files', [u2]);

      await store.recycleRestore(rp);
      final (data, _, __) = await store.read(dev, 'files', 'r.txt', 0, 64);
      expect(utf8.decode(data), 'old'); // v1 归位
      // v2 应在回收站
      final recycle = await store.recycleList();
      expect(recycle.any((e) => e.originPath == 'r.txt'), isTrue);
    });

    test('清空回收站返回清理字节数', () async {
      final c = bytesOf('purge');
      final (u, _) = await begin('p.txt', c);
      await store.writeChunk(dev, 'files', u, 0, c);
      await store.commit(dev, 'files', [u]);
      await store.delete(dev, 'files', 'p.txt');

      final purged = await store.recycleEmpty();
      expect(purged, c.length);
      expect(await store.recycleList(), isEmpty);
    });

    test('目录递归删除入回收站', () async {
      final c = bytesOf('nested');
      final (u, _) = await begin('dir/sub/n.txt', c);
      await store.writeChunk(dev, 'files', u, 0, c);
      await store.commit(dev, 'files', [u]);

      await store.delete(dev, 'files', 'dir');
      expect(await store.list(dev, 'files'), isEmpty);
      final entries = await store.recycleList();
      expect(entries.single.originPath, 'dir');
      await store.recycleRestore(entries.single.recyclePath);
      expect((await store.list(dev, 'files')).single.path, 'dir/sub/n.txt');
    });
  });

  group('stats/gc/安全', () {
    test('stats 按设备与分区统计', () async {
      final c = bytesOf('stat');
      final (u, _) = await begin('s.txt', c, space: 'artifacts');
      await store.writeChunk(dev, 'artifacts', u, 0, c);
      await store.commit(dev, 'artifacts', [u]);

      final (u2, _) = await store.writeBegin(
          deviceId: devB,
          space: 'files',
          path: 'b.txt',
          size: c.length,
          sha256: sha(c));
      await store.writeChunk(devB, 'files', u2, 0, c);

      final stats = await store.stats();
      final devices = stats['devices'] as Map;
      expect(devices[dev]['artifacts'], c.length);
      expect(devices[devB]['files'], 0); // 未 commit
      expect(stats['staging_bytes'], greaterThan(0));
    });

    test('gcStaging 清理超期暂存', () async {
      final (u, _) = await begin('stale.txt', bytesOf('stale'));
      await store.writeChunk(dev, 'files', u, 0, bytesOf('st'));
      // 手工把 staging 文件 mtime 改到 2 天前
      final stagingDir = Directory(p.join(tmp.path, dev, 'files', '.staging'));
      await for (final f in stagingDir.list()) {
        if (f is File) {
          await f.setLastModified(
              DateTime.now().subtract(const Duration(days: 2)));
        }
      }
      final removed = await store.gcStaging();
      expect(removed, 1);
      // 再 commit 应报 unknown upload_id
      final (committed, failed) = await store.commit(dev, 'files', [u]);
      expect(committed, isEmpty);
      expect(failed.single, contains('unknown upload_id'));
    });

    test('路径穿越攻击在 FS 层同样被拒', () async {
      expect(() => store.delete(dev, 'files', '../../../etc/passwd'),
          throwsA(isA<BadPathException>()));
      expect(
          () => store.writeBegin(
              deviceId: dev,
              space: 'files',
              path: '/abs/x',
              size: 1,
              sha256: sha(bytesOf('x'))),
          throwsA(isA<BadPathException>()));
      // 伪造 device_id 形态
      expect(() => store.list('not-a-device', 'files'),
          throwsA(predicate(
              (e) => e is StoreException && e.code == StoreError.badOp)));
    });
  });
}

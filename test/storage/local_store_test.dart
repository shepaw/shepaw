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
      expect(committed.map((f) => f.path), ['a/b.txt']);
      expect(failed, isEmpty);

      final list = await store.list(dev, 'files');
      expect(list.single.path, 'a/b.txt');
      expect(list.single.sha256, sha(content));
      expect(list.single.size, content.length);
    });

    test('depth=1 一层列出目录与文件（跨 agent 下钻）', () async {
      for (final agent in ['agent-aaa', 'agent-bbb']) {
        final content = bytesOf('note-$agent');
        final (u, _) = await begin('$agent/note.txt', content, space: 'agents');
        await store.writeChunk(dev, 'agents', u, 0, content);
        await store.commit(dev, 'agents', [u]);
      }

      final root = await store.list(dev, 'agents', depth: 1);
      expect(root.map((e) => e.path).toList()..sort(),
          ['agent-aaa', 'agent-bbb']);
      expect(root.every((e) => e.isDir), isTrue);

      final one =
          await store.list(dev, 'agents', prefix: 'agent-aaa', depth: 1);
      expect(one, hasLength(1));
      expect(one.single.path, 'agent-aaa/note.txt');
      expect(one.single.kind, 'file');
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
      expect(c2.map((f) => f.path), ['x.txt']);
      expect(f2, isEmpty);
    });

    test('批内任一校验失败则整批不转正（spec §2.6）', () async {
      final good = bytesOf('ok-content');
      final badDeclared = bytesOf('declared');
      final (uGood, _) = await begin('good.txt', good);
      await store.writeChunk(dev, 'files', uGood, 0, good);
      final (uBad, _) = await begin('bad.txt', badDeclared);
      await store.writeChunk(dev, 'files', uBad, 0, bytesOf('WRONG!!!'));

      final (committed, failed) =
          await store.commit(dev, 'files', [uGood, uBad]);
      expect(committed, isEmpty);
      expect(failed, isNotEmpty);
      expect(failed.any((f) => f.contains('hash mismatch')), isTrue);
      // 好文件也不得提前转正
      expect(await store.list(dev, 'files'), isEmpty);
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
      expect(committed.map((f) => f.path), ['resume.txt']);
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

    test('write.chunk 超过 64KB 拒绝', () async {
      final big = Uint8List(LocalStore.maxReadChunk + 1);
      final (uploadId, _) = await begin('toobig.bin', big);
      expect(
        () => store.writeChunk(dev, 'files', uploadId, 0, big),
        throwsA(predicate((e) =>
            e is StoreException && e.code == StoreError.badOp)),
      );
    });

    test('commit 目标路径含 symlink 时拒绝转正', () async {
      final content = bytesOf('escape');
      final (uploadId, _) = await begin('linky/x.txt', content);
      await store.writeChunk(dev, 'files', uploadId, 0, content);

      final spaceDir = Directory(p.join(tmp.path, dev, 'files'));
      await spaceDir.create(recursive: true);
      final outside = await Directory.systemTemp.createTemp('symlink_out');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      try {
        await Link(p.join(spaceDir.path, 'linky')).create(outside.path);
      } on FileSystemException catch (_) {
        // 部分 CI/沙箱禁止创建 symlink，跳过
        return;
      }

      final (committed, failed) =
          await store.commit(dev, 'files', [uploadId]);
      expect(committed, isEmpty);
      expect(failed, isNotEmpty);
      expect(failed.single.toLowerCase(), contains('symlink'));
    });
  });

  group('read/meta', () {
    test('分块读取与 eof', () async {
      final content = Uint8List.fromList(
          List.generate(200 * 1024, (i) => i % 256));
      final (uploadId, _) = await begin('big.bin', content);
      // 按协议 ≤64KB 分块写入
      var off = 0;
      while (off < content.length) {
        final end = (off + LocalStore.maxReadChunk < content.length)
            ? off + LocalStore.maxReadChunk
            : content.length;
        await store.writeChunk(
            dev, 'files', uploadId, off, content.sublist(off, end));
        off = end;
      }
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
      // 手工把 staging meta 的 created_ms 改到 2 天前（GC 按创建时间，非 mtime）
      final metaFile =
          File(p.join(tmp.path, dev, 'files', '.staging', '$u.json'));
      final meta =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      meta['created_ms'] =
          DateTime.now().subtract(const Duration(days: 2)).millisecondsSinceEpoch;
      await metaFile.writeAsString(jsonEncode(meta));
      final removed = await store.gcStaging();
      expect(removed, 1);
      // 再 commit 应报 unknown upload_id
      final (committed, failed) = await store.commit(dev, 'files', [u]);
      expect(committed, isEmpty);
      expect(failed.single, contains('unknown upload_id'));
    });

    test('gcRecycle 清理超过 30 天的日期目录', () async {
      final c = bytesOf('old-trash');
      final (u, _) = await begin('old.txt', c);
      await store.writeChunk(dev, 'files', u, 0, c);
      await store.commit(dev, 'files', [u]);
      await store.delete(dev, 'files', 'old.txt');

      // 把今日目录改名为 31 天前
      final recycleRoot = Directory(p.join(tmp.path, '.recycle'));
      final todayName = p.basename((await recycleRoot.list().first).path);
      final oldDate = DateTime.now().subtract(const Duration(days: 31));
      final oldName =
          '${oldDate.year}-${oldDate.month.toString().padLeft(2, '0')}-${oldDate.day.toString().padLeft(2, '0')}';
      await Directory(p.join(recycleRoot.path, todayName))
          .rename(p.join(recycleRoot.path, oldName));

      expect(await store.recycleList(), isNotEmpty);
      final purged = await store.gcRecycle();
      expect(purged, greaterThan(0));
      expect(await store.recycleList(), isEmpty);
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
      // 非法 space 名（非自定义语法）
      expect(() => store.list(dev, '../escape'),
          throwsA(predicate((e) =>
              e is StoreException &&
              e.code == StoreError.badOp &&
              e.message == 'invalid space')));
      // 合法自定义空间（如 memory）可 list，目录不存在时返回空
      expect(await store.list(dev, StoreSpace.memory), isEmpty);
    });

    test('purgeDevice 删他端目录且禁删本机', () async {
      final c = bytesOf('purge-me');
      final (u, _) = await store.writeBegin(
          deviceId: devB,
          space: 'files',
          path: 'old.txt',
          size: c.length,
          sha256: sha(c));
      await store.writeChunk(devB, 'files', u, 0, c);
      await store.commit(devB, 'files', [u]);

      expect(
          () => store.purgeDevice(dev, selfDeviceId: dev),
          throwsA(predicate(
              (e) => e is StoreException && e.code == StoreError.aclDenied)));

      final freed = await store.purgeDevice(devB, selfDeviceId: dev);
      expect(freed, c.length);
      expect(await Directory(p.join(tmp.path, devB)).exists(), isFalse);
      final stats = await store.stats();
      expect((stats['devices'] as Map).containsKey(devB), isFalse);

      expect(
          () => store.purgeDevice(devB, selfDeviceId: dev),
          throwsA(predicate(
              (e) => e is StoreException && e.code == StoreError.notFound)));
    });

    test('wipeSelf 清空本机目录且不删他端', () async {
      final c = bytesOf('wipe-self');
      final (u, _) = await begin('keep-peer.txt', c);
      await store.writeChunk(dev, 'files', u, 0, c);
      await store.commit(dev, 'files', [u]);

      final (u2, _) = await store.writeBegin(
          deviceId: devB,
          space: 'files',
          path: 'peer.txt',
          size: c.length,
          sha256: sha(c));
      await store.writeChunk(devB, 'files', u2, 0, c);
      await store.commit(devB, 'files', [u2]);

      final freed = await store.wipeSelf(dev);
      expect(freed, greaterThanOrEqualTo(c.length));
      expect(await store.list(dev, 'files'), isEmpty);
      expect((await store.list(devB, 'files')).single.path, 'peer.txt');
      expect(await Directory(p.join(tmp.path, '.recycle')).exists(), isFalse);
    });
  });
}

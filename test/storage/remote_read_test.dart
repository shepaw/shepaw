import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/storage/local_cas.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/remote_read_service.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// CAS + 读路径缓存校验（spec §7）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  tearDown(() {
    RemoteReadService.instance.serverCaller = null;
    RemoteReadService.instance.retryWait = null;
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  group('LocalCas', () {
    test('put 去重 + get + materialize', () async {
      final tmp = await Directory.systemTemp.createTemp('cas_test');
      final cas = LocalCas(storeRoot: tmp);
      final content = bytesOf('content-addressed');
      final b1 = await cas.put(content, synced: true);
      final b2 = await cas.put(content, synced: true);
      expect(b1.path, b2.path); // 同 hash 同一 blob
      expect(await cas.totalBytes(), content.length);

      final target = p.join(tmp.path, 'out.txt');
      await cas.materialize(sha(content), target);
      expect(await File(target).readAsBytes(), content);
    });

    test('LRU 淘汰：未同步不可淘汰', () async {
      final tmp = await Directory.systemTemp.createTemp('cas_evict');
      final cas = LocalCas(storeRoot: tmp);
      final synced = bytesOf('synced blob ok to evict');
      final unsynced = bytesOf('unsynced protected!!');
      await cas.put(synced, synced: true);
      await Future.delayed(const Duration(milliseconds: 5));
      await cas.put(unsynced, synced: false);

      final freed = await cas.evict(capBytes: 10);
      expect(freed, synced.length);
      // synced 被淘汰，unsynced 保留
      expect(await cas.get(sha(synced)), isNull);
      expect(await cas.get(sha(unsynced)), isNotNull);
    });
  });

  group('RemoteReadService（spec §7 流程）', () {
    const server = 'aaaaaaaaaaaaaaaa';
    const device = 'bbbbbbbbbbbbbbbb';
    late Directory serverRoot;
    late LocalStore serverStore;
    late List<String> opLog;
    late bool serverOnline;

    Future<void> serverWrite(String path, Uint8List content) async {
      final (uid, _) = await serverStore.writeBegin(
          deviceId: device,
          space: 'files',
          path: path,
          size: content.length,
          sha256: sha(content));
      await serverStore.writeChunk(device, 'files', uid, 0, content);
      await serverStore.commit(device, 'files', [uid]);
    }

    setUp(() async {
      serverRoot = await Directory.systemTemp.createTemp('rr_server');
      serverStore = LocalStore(root: serverRoot);
      opLog = <String>[];
      serverOnline = true;
      RemoteReadService.instance.serverCaller =
          (serverDeviceId, frame) async {
        if (!serverOnline) {
          return <String, dynamic>{'_error': StoreError.masterOffline};
        }
        opLog.add(frame.op);
        switch (frame.op) {
          case StoreOp.meta:
            final meta = await serverStore.meta(
                frame.payload['device'] as String,
                frame.payload['space'] as String,
                frame.payload['path'] as String);
            return meta;
          case StoreOp.read:
            final (data, size, eof) = await serverStore.read(
                frame.payload['device'] as String,
                frame.payload['space'] as String,
                frame.payload['path'] as String,
                frame.payload['offset'] as int,
                frame.payload['length'] as int);
            return {
              'data': base64Encode(data),
              'size': size,
              'eof': eof,
            };
          default:
            return <String, dynamic>{'_error': 'unsupported'};
        }
      };
    });

    test('无缓存下载；hash 一致二次读取零内容流量（只有 meta）', () async {
      final content = bytesOf('cache me once');
      await serverWrite('doc/a.txt', content);

      final r1 = await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/a.txt');
      expect(r1.bytes, content);
      expect(r1.stale, isFalse);
      expect(opLog.where((op) => op == StoreOp.read).length, 1);

      // 二次：只有 meta，无 read（零内容流量，§7-1）
      opLog.clear();
      final r2 = await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/a.txt');
      expect(r2.bytes, content);
      expect(opLog.where((op) => op == StoreOp.read), isEmpty);
      expect(opLog.where((op) => op == StoreOp.meta), isNotEmpty);
    });

    test('内容变更后重新下载', () async {
      await serverWrite('doc/b.txt', bytesOf('version 1'));
      await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/b.txt');
      await serverWrite('doc/b.txt', bytesOf('version 2!'));
      final r = await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/b.txt');
      expect(utf8.decode(r.bytes), 'version 2!');
    });

    test('master 离线：有缓存标注 stale 使用；无缓存报错', () async {
      await serverWrite('doc/c.txt', bytesOf('cached'));
      await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/c.txt');

      serverOnline = false;
      final r = await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/c.txt');
      expect(utf8.decode(r.bytes), 'cached');
      expect(r.stale, isTrue);

      expect(
        () => RemoteReadService.instance.readVerified(
            serverDeviceId: server,
            deviceId: device,
            space: 'files',
            path: 'doc/never.txt'),
        throwsStateError,
      );
    });

    test('not_found 短暂缺失后重试成功', () async {
      RemoteReadService.instance.retryWait = (_) async {};
      var metaCalls = 0;
      final content = bytesOf('appears after sync');
      await serverWrite('doc/lag.txt', content);

      // 前两次 meta 假装尚未镜像到 master
      final realCaller = RemoteReadService.instance.serverCaller!;
      RemoteReadService.instance.serverCaller =
          (serverDeviceId, frame) async {
        if (frame.op == StoreOp.meta) {
          metaCalls++;
          if (metaCalls <= 2) {
            return <String, dynamic>{'_error': StoreError.notFound};
          }
        }
        return realCaller(serverDeviceId, frame);
      };

      final r = await RemoteReadService.instance.readVerified(
          serverDeviceId: server,
          deviceId: device,
          space: 'files',
          path: 'doc/lag.txt');
      expect(r.bytes, content);
      expect(metaCalls, greaterThanOrEqualTo(3));
    });

    test('not_found 耗尽重试后抛出', () async {
      RemoteReadService.instance.retryWait = (_) async {};
      RemoteReadService.instance.serverCaller =
          (serverDeviceId, frame) async {
        if (frame.op == StoreOp.meta) {
          return <String, dynamic>{'_error': StoreError.notFound};
        }
        return <String, dynamic>{'_error': 'unsupported'};
      };

      expect(
        () => RemoteReadService.instance.readVerified(
            serverDeviceId: server,
            deviceId: device,
            space: 'files',
            path: 'doc/missing.txt'),
        throwsA(isA<StoreException>()
            .having((e) => e.code, 'code', StoreError.notFound)),
      );
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shepaw/peer/models/peer_store_share.dart';
import 'package:shepaw/storage/device_cursor_store.dart';
import 'package:shepaw/storage/device_identity.dart';
import 'package:shepaw/storage/import_auth_service.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import 'test_harness.dart';

/// StoreService loopback 端到端 + 攻击 fixture（docs/storage_protocol_spec.md §4）。
/// master 默认本机 → call() 走 loopback dispatch。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  Uint8List bytesOf(String s) => Uint8List.fromList(utf8.encode(s));
  String sha(Uint8List b) => crypto.sha256.convert(b).toString();

  Future<Map<String, dynamic>?> writeFile(
      String path, Uint8List content) async {
    final begin = await StoreService.instance.call(StoreFrame(
        op: StoreOp.writeBegin,
        payload: {
          'space': 'files',
          'path': path,
          'size': content.length,
          'sha256': sha(content),
        }));
    final uploadId = begin!['upload_id'] as String;
    final chunk = await StoreService.instance.call(StoreFrame(
        op: StoreOp.writeChunk,
        payload: {
          'space': 'files',
          'upload_id': uploadId,
          'offset': 0,
          'data': base64Encode(content),
        }));
    expect(chunk!['received'], content.length);
    return StoreService.instance.call(StoreFrame(
        op: StoreOp.commit,
        payload: {
          'space': 'files',
          'upload_ids': [uploadId],
        }));
  }

  group('loopback 读写闭环（所有端经 store.* 读写）', () {
    test('write.begin→chunk→commit→list→read→delete 全链路', () async {
      final content = bytesOf('loopback hello');
      final commit = await writeFile('e2e/a.txt', content);
      expect(commit!['committed'], ['e2e/a.txt']);

      final list = await StoreService.instance.call(StoreFrame(
          op: StoreOp.list, payload: {'space': 'files', 'path': 'e2e/'}));
      expect((list!['entries'] as List).single['path'], 'e2e/a.txt');

      final read = await StoreService.instance.call(StoreFrame(
          op: StoreOp.read,
          payload: {'space': 'files', 'path': 'e2e/a.txt', 'offset': 0, 'length': 1024}));
      expect(utf8.decode(base64Decode(read!['data'] as String)),
          'loopback hello');

      final meta = await StoreService.instance.call(StoreFrame(
          op: StoreOp.meta, payload: {'space': 'files', 'path': 'e2e/a.txt'}));
      expect(meta!['sha256'], sha(content));

      final deleted = await StoreService.instance.call(StoreFrame(
          op: StoreOp.delete, payload: {'space': 'files', 'path': 'e2e/a.txt'}));
      expect(deleted!['recycled'], startsWith('.recycle/'));
    });

    test('recycle.empty loopback 放行', () async {
      await writeFile('e2e/trash.txt', bytesOf('x'));
      await StoreService.instance.call(StoreFrame(
          op: StoreOp.delete, payload: {'space': 'files', 'path': 'e2e/trash.txt'}));
      final emptied = await StoreService.instance
          .call(StoreFrame(op: StoreOp.recycleEmpty, payload: {}));
      expect(emptied!['purged_bytes'], greaterThan(0));
    });
  });

  group('攻击 fixture（spec §4）', () {
    test('伪造 device_id 写入：拒绝且目标目录无文件', () async {
      final content = bytesOf('forged');
      final res = await StoreService.instance.call(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': 'files',
            'path': 'victim.txt',
            'size': content.length,
            'sha256': sha(content),
            'device': 'bbbbbbbbbbbbbbbb', // 伪造他端目录
          }));
      expect(res!['_error'], StoreError.aclDenied);

      // 他端与本端目录都不该出现该文件
      final mine = await DeviceIdentity.deviceId();
      final listB = await StoreService.instance.call(StoreFrame(
          op: StoreOp.list,
          payload: {'space': 'files', 'device': 'bbbbbbbbbbbbbbbb'}));
      expect((listB!['entries'] as List), isEmpty);
      final listMine = await StoreService.instance.call(StoreFrame(
          op: StoreOp.list, payload: {'space': 'files', 'device': mine}));
      expect(
          (listMine!['entries'] as List)
              .any((e) => (e as Map)['path'] == 'victim.txt'),
          isFalse);
    });

    test('读取他人私有目录：拒绝', () async {
      final res = await StoreService.instance.call(StoreFrame(
          op: StoreOp.read,
          payload: {
            'space': 'backups',
            'device': 'bbbbbbbbbbbbbbbb',
            'path': 'snap/db.sqlite.enc',
            'offset': 0,
            'length': 1024,
          }));
      expect(res!['_error'], StoreError.aclDenied);
    });

    test('路径穿越：拒绝', () async {
      for (final path in [
        '../../../etc/passwd',
        '/etc/passwd',
        '..',
        'a/../../b',
      ]) {
        final res = await StoreService.instance.call(StoreFrame(
            op: StoreOp.writeBegin,
            payload: {
              'space': 'files',
              'path': path,
              'size': 1,
              'sha256': sha(bytesOf('x')),
            }));
        expect(res!['_error'], isNotNull, reason: 'path=$path');
      }
    });

    test('伪造导入授权 op：bad_op', () async {
      final res = await StoreService.instance.call(StoreFrame(
          op: 'import.auth',
          payload: {'grant': 'allow-everything'}));
      expect(res!['_error'], StoreError.badOp);
    });

    test('friend 级：自有可读；跨端无白名单拒绝；管理类 untrusted', () async {
      final self = await DeviceIdentity.deviceId();
      const other = 'bbbbbbbbbbbbbbbb';
      final own = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.list, payload: {'space': 'files'}),
        callerDeviceId: self,
        trustLevel: TrustLevel.friend,
      );
      expect(own.containsKey('_error'), isFalse);

      final cross = await StoreService.instance.dispatchForTest(
        StoreFrame(
            op: StoreOp.list,
            payload: {'space': 'files', 'device': other}),
        callerDeviceId: self,
        trustLevel: TrustLevel.friend,
      );
      expect(cross['_error'], StoreError.aclDenied);

      final stats = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.stats, payload: {}),
        callerDeviceId: self,
        trustLevel: TrustLevel.friend,
      );
      expect(stats['_error'], StoreError.untrusted);
    });

    test('有效 grant 可读他人 backups；伪造 grant 拒绝', () async {
      const oldDev = 'bbbbbbbbbbbbbbbb';
      final self = await DeviceIdentity.deviceId();
      final docs = await getApplicationDocumentsDirectory();
      final storeRoot = Directory(p.join(docs.path, 'shepaw', 'store'));
      // 在旧设备 backups 下直接落一份可读文件
      final snapDir = Directory(
          p.join(storeRoot.path, oldDev, 'backups', '20260726-120000'));
      await snapDir.create(recursive: true);
      final payload = utf8.encode('old-backup-bytes');
      await File(p.join(snapDir.path, 'manifest.json'))
          .writeAsString('{"ok":true}');
      await File(p.join(snapDir.path, 'db.sqlite.enc'))
          .writeAsBytes(payload);

      final auth = ImportAuthService(storeRoot: storeRoot);
      final req = await auth.createRequest(oldDevice: oldDev, newDevice: self);
      final grant = await auth.grant(req.request.requestId);

      final denied = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.list, payload: {
          'space': 'backups',
          'device': oldDev,
          'path': '',
          'grant': 'ig-forged',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
      );
      expect(denied['_error'], StoreError.aclDenied);

      final ok = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.list, payload: {
          'space': 'backups',
          'device': oldDev,
          'path': '20260726-120000/',
          'grant': grant.grantId,
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
      );
      expect(ok.containsKey('_error'), isFalse);
      final paths = (ok['entries'] as List)
          .map((e) => (e as Map)['path'] as String)
          .toList();
      expect(paths, contains('20260726-120000/db.sqlite.enc'));
    });

    test('路径 B：master 代签推送采信 payload old_device', () async {
      const lostOld = 'dddddddddddddddd';
      const masterIssuer = 'eeeeeeeeeeeeeeee'; // ≠ old_device
      final self = await DeviceIdentity.deviceId();
      final docs = await getApplicationDocumentsDirectory();
      final storeRoot = Directory(p.join(docs.path, 'shepaw', 'store'));
      final auth = ImportAuthService(storeRoot: storeRoot);

      await StoreService.instance.receivePushedGrantForTest(
        masterIssuer,
        StoreFrame(op: StoreOp.importGrant, payload: {
          'grant_id': 'ig-path-b-test',
          'old_device': lostOld,
          'spaces': ['backups', 'attachments'],
          'issued_at': 1,
          'expires_at': 9999999999999,
        }),
      );

      final received = await auth.receivedGrants();
      final hit = received.where((g) => g.grantId == 'ig-path-b-test').toList();
      expect(hit, isNotEmpty);
      expect(hit.single.oldDevice, lostOld);
      expect(hit.single.oldDevice, isNot(masterIssuer));
      expect(hit.single.newDevice, self);
    });
  });

  group('远端 master 不可达', () {
    test('master 指针指向未配对设备 → not_paired / master_offline', () async {
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId('cccccccccccccccc');
      try {
        final res = await StoreService.instance.call(StoreFrame(
            op: StoreOp.stats, payload: {}));
        expect(res!['_error'], anyOf(StoreError.notPaired, StoreError.masterOffline));
      } finally {
        await StoreService.instance.setMasterDeviceId(self);
      }
    });
  });

  group('purgeMirroredDevice', () {
    test('删他端目录并清游标', () async {
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId(self);
      const other = 'aaaaaaaaaaaaaaaa';
      final store = await StoreService.instance.localStore();
      final content = bytesOf('mirror-blob');
      final (uid, _) = await store.writeBegin(
        deviceId: other,
        space: StoreSpace.files,
        path: 'kept.txt',
        size: content.length,
        sha256: sha(content),
      );
      await store.writeChunk(other, StoreSpace.files, uid, 0, content);
      await store.commit(other, StoreSpace.files, [uid]);
      expect(await store.list(other, StoreSpace.files), isNotEmpty);

      final cursors = DeviceCursorStore(storeRoot: store.root);
      await cursors.advance(other, 9);

      final freed = await StoreService.instance.purgeMirroredDevice(other);
      expect(freed, greaterThan(0));
      expect(await store.list(other, StoreSpace.files), isEmpty);
      final after = DeviceCursorStore(storeRoot: store.root);
      expect((await after.all()).containsKey(other), isFalse);
    });

    test('非 master 拒绝', () async {
      final self = await DeviceIdentity.deviceId();
      await StoreService.instance.setMasterDeviceId('bbbbbbbbbbbbbbbb');
      try {
        await expectLater(
          StoreService.instance.purgeMirroredDevice('aaaaaaaaaaaaaaaa'),
          throwsA(isA<StoreException>()
              .having((e) => e.code, 'code', StoreError.notMaster)),
        );
      } finally {
        await StoreService.instance.setMasterDeviceId(self);
      }
    });
  });

  group('runtime 分享（shareAllowlist）', () {
    const other = '9999999999999999';
    const hash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

    final allowlist = PeerStoreShareAllowlist.fromEntries(const [
      PeerStoreShareEntry(space: StoreSpace.runtime, path: 'agent_1'),
    ]);

    setUpAll(() async {
      final docs = await getApplicationDocumentsDirectory();
      final storeRoot = Directory(p.join(docs.path, 'shepaw', 'store'));
      final runtimeRoot =
          Directory(p.join(storeRoot.path, other, 'runtime', 'agent_1'));
      final attachDir =
          Directory(p.join(runtimeRoot.path, 'ch_1', 'attachments'));
      await attachDir.create(recursive: true);
      await File(p.join(attachDir.path, hash))
          .writeAsBytes(utf8.encode('attach-bytes'));
      final artifactDir =
          Directory(p.join(runtimeRoot.path, 'ch_1', 'artifacts', 'task_1'));
      await artifactDir.create(recursive: true);
      await File(p.join(artifactDir.path, 'out.txt'))
          .writeAsString('artifact-out');
      await File(p.join(runtimeRoot.path, 'soul.md')).writeAsString('# soul');
      final sessionDir =
          Directory(p.join(runtimeRoot.path, 'ch_1', 'sessions'));
      await sessionDir.create(recursive: true);
      await File(p.join(sessionDir.path, 'session.json')).writeAsString('{}');
    });

    test('附件/产物可跨端 read/meta，soul/会话/未知文件拒绝', () async {
      final self = await DeviceIdentity.deviceId();
      final readRes = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.read, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1/ch_1/attachments/$hash',
          'offset': 0,
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(readRes.containsKey('_error'), isFalse);
      expect(
        utf8.decode(base64Decode(readRes['data'] as String)),
        'attach-bytes',
      );

      final artifactMeta = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.meta, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1/ch_1/artifacts/task_1/out.txt',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(artifactMeta['kind'], 'file');
      expect(artifactMeta['size'], 'artifact-out'.length);

      // 目录可导航；不随附子清单（防 session.json 经目录 meta 泄露）
      final dirMeta = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.meta, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1/ch_1',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(dirMeta['kind'], 'dir');
      expect(dirMeta.containsKey('files'), isFalse);

      for (final deniedPath in [
        'agent_1/soul.md',
        'agent_1/ch_1/sessions/session.json',
        'agent_1/ch_1/session.md', // channel 根未知文件
      ]) {
        final denied = await StoreService.instance.dispatchForTest(
          StoreFrame(op: StoreOp.meta, payload: {
            'space': StoreSpace.runtime,
            'device': other,
            'path': deniedPath,
          }),
          callerDeviceId: self,
          trustLevel: TrustLevel.owner,
          shareAllowlist: allowlist,
        );
        expect(denied['_error'], StoreError.aclDenied, reason: deniedPath);
      }
    });

    test('list 过滤：目录/附件/产物可见，soul/会话文件不可见', () async {
      final self = await DeviceIdentity.deviceId();
      // 有限 depth：目录出现且可导航，soul.md 等根文件被过滤
      final shallow = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.list, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1',
          'depth': 1,
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(shallow.containsKey('_error'), isFalse);
      final shallowPaths = (shallow['entries'] as List)
          .map((e) => (e as Map)['path'] as String)
          .toList();
      expect(shallowPaths, contains('agent_1/ch_1')); // 目录可导航
      expect(shallowPaths, isNot(contains('agent_1/soul.md')));

      // 全深度：附件/产物文件可见，会话文件被过滤
      final deep = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.list, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(deep.containsKey('_error'), isFalse);
      final deepPaths = (deep['entries'] as List)
          .map((e) => (e as Map)['path'] as String)
          .toList();
      expect(deepPaths, contains('agent_1/ch_1/attachments/$hash'));
      expect(deepPaths, contains('agent_1/ch_1/artifacts/task_1/out.txt'));
      expect(deepPaths, isNot(contains('agent_1/ch_1/sessions/session.json')));
    });

    test('无白名单（null）：分享路径仍拒绝（grant 闸门回归）', () async {
      final self = await DeviceIdentity.deviceId();
      final denied = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.meta, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'agent_1/ch_1/attachments/$hash',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
      );
      expect(denied['_error'], StoreError.aclDenied);
    });

    test('白名单未覆盖的 owner 前缀仍拒绝', () async {
      final self = await DeviceIdentity.deviceId();
      final denied = await StoreService.instance.dispatchForTest(
        StoreFrame(op: StoreOp.meta, payload: {
          'space': StoreSpace.runtime,
          'device': other,
          'path': 'other_owner/ch_9/attachments/$hash',
        }),
        callerDeviceId: self,
        trustLevel: TrustLevel.owner,
        shareAllowlist: allowlist,
      );
      expect(denied['_error'], StoreError.aclDenied);
    });
  });
}

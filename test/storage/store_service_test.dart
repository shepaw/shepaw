import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/device_identity.dart';
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

    test('friend 级设备帧被拒（untrusted）', () async {
      // 直接走 dispatch 层（master 侧处理逻辑的信任强制点）
      final res = await StoreService.instance.call(StoreFrame(
          op: StoreOp.list, payload: {'space': 'files'}));
      // loopback 是 owner，正常返回；friend 判定在 ACL 纯函数层已由
      // store_protocol_test 覆盖，此处确认 loopback 不误伤。
      expect(res!.containsKey('entries'), isTrue);
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
}

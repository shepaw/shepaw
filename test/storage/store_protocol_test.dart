import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/store_protocol.dart';

/// store.* 协议纯逻辑（docs/storage_protocol_spec.md v1）：
/// 帧编解码、路径规范化（含攻击用例）、ACL 矩阵（含 friend/伪造 device_id）。
void main() {
  group('StoreFrame', () {
    test('编解码往返', () {
      final frame = StoreFrame(
          op: StoreOp.read,
          reqId: 'r-1',
          payload: {'space': 'artifacts', 'path': 'a/b.txt', 'offset': 0});
      final wire = frame.toJson();
      expect(wire['type'], kStoreControlType);
      expect(wire['ns'], kStoreControlType);
      final parsed = StoreFrame.tryParse(wire)!;
      expect(parsed.op, StoreOp.read);
      expect(parsed.reqId, 'r-1');
      expect(parsed.space, 'artifacts');
      expect(parsed.path, 'a/b.txt');
      expect(parsed.payload.containsKey('type'), isFalse);
    });

    test('非 store 帧返回 null；缺 op 抛异常', () {
      expect(StoreFrame.tryParse({'ns': 'sync', 'op': 'x'}), isNull);
      expect(() => StoreFrame.tryParse({'ns': 'store'}),
          throwsFormatException);
    });

    test('result/error 构造器', () {
      final ok = storeResult('r-1', {'size': 1});
      expect(ok.toJson()['op'], 'result');
      expect(ok.toJson()['data'], {'size': 1});
      final err = storeError('r-1', StoreError.aclDenied, 'no');
      expect(err.toJson()['code'], 'acl_denied');
      expect(err.toJson()['message'], 'no');
    });
  });

  group('normalizeStorePath', () {
    test('合法路径规范化', () {
      expect(normalizeStorePath('a/b/c.txt'), 'a/b/c.txt');
      expect(normalizeStorePath('a//b/./c'), 'a/b/c');
      expect(normalizeStorePath(r'a\b\c'), 'a/b/c'); // 反斜杠统一
      expect(normalizeStorePath('task-41/report.md'), 'task-41/report.md');
    });

    test('攻击用例：绝对路径/穿越/盘符/NUL/点段（共享 fixture）', () {
      final file = File('docs/storage_fixtures/path_attacks.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final attacks = (json['attacks'] as List).cast<String>();
      for (final path in attacks) {
        expect(() => normalizeStorePath(path), throwsA(isA<BadPathException>()),
            reason: 'should reject: $path');
      }
    });
  });

  test('isValidDeviceId', () {
    expect(isValidDeviceId('0123456789abcdef'), isTrue);
    expect(isValidDeviceId('0123456789ABCDEF'), isFalse);
    expect(isValidDeviceId('short'), isFalse);
    expect(isValidDeviceId(null), isFalse);
  });

  group('ACL 矩阵（spec §3）', () {
    const caller = 'aaaaaaaaaaaaaaaa';
    const other = 'bbbbbbbbbbbbbbbb';

    StoreAcl acl(StoreFrame f,
            {String trust = TrustLevel.owner, bool loopback = false}) =>
        checkStoreAcl(f,
            callerDeviceId: caller, trustLevel: trust, loopback: loopback);

    test('friend 级全部拒绝', () {
      for (final op in [
        StoreOp.list,
        StoreOp.read,
        StoreOp.writeBegin,
        StoreOp.commit,
        StoreOp.delete,
        StoreOp.stats,
        StoreOp.recycleList,
        StoreOp.recycleEmpty,
      ]) {
        final v = acl(
            StoreFrame(op: op, payload: {'space': 'artifacts'}),
            trust: TrustLevel.friend);
        expect(v, StoreAcl.denyUntrusted, reason: 'op=$op');
      }
    });

    test('写路径收敛：自有可写，伪造 device_id 拒绝', () {
      // device 缺省 → 调用者目录
      expect(
          acl(StoreFrame(
              op: StoreOp.writeBegin,
              payload: {'space': 'artifacts', 'path': 'x'})),
          StoreAcl.allow);
      // device == 调用者
      expect(
          acl(StoreFrame(
              op: StoreOp.writeBegin,
              payload: {'space': 'artifacts', 'path': 'x', 'device': caller})),
          StoreAcl.allow);
      // 伪造 device_id 写入他人目录 → 拒绝
      expect(
          acl(StoreFrame(
              op: StoreOp.writeBegin,
              payload: {'space': 'artifacts', 'path': 'x', 'device': other})),
          StoreAcl.denyAcl);
      // commit 同样收敛
      expect(
          acl(StoreFrame(
              op: StoreOp.commit,
              payload: {'space': 'files', 'upload_ids': [], 'device': other})),
          StoreAcl.denyAcl);
    });

    test('共享分区跨端可读可删；私有分区仅本端', () {
      // 读他端 artifacts/files → 允许
      expect(
          acl(StoreFrame(
              op: StoreOp.read,
              payload: {'space': 'files', 'device': other, 'path': 'x'})),
          StoreAcl.allow);
      // 读他端 attachments/backups → 拒绝
      for (final space in ['attachments', 'backups']) {
        expect(
            acl(StoreFrame(
                op: StoreOp.read,
                payload: {'space': space, 'device': other, 'path': 'x'})),
            StoreAcl.denyAcl,
            reason: 'read $space of other device');
        // 删除他端私有分区 → 拒绝
        expect(
            acl(StoreFrame(
                op: StoreOp.delete,
                payload: {'space': space, 'device': other, 'path': 'x'})),
            StoreAcl.denyAcl,
            reason: 'delete $space of other device');
      }
      // 删除他端共享分区 → 允许（共享文件手动删除）
      expect(
          acl(StoreFrame(
              op: StoreOp.delete,
              payload: {'space': 'files', 'device': other, 'path': 'x'})),
          StoreAcl.allow);
    });

    test('回收站清空仅 master 本机（loopback）', () {
      expect(acl(StoreFrame(op: StoreOp.recycleEmpty, payload: {})),
          StoreAcl.denyAcl);
      expect(
          acl(StoreFrame(op: StoreOp.recycleEmpty, payload: {}),
              loopback: true),
          StoreAcl.allow);
    });

    test('伪造导入授权 op → bad_op', () {
      expect(
          acl(StoreFrame(
              op: 'import.auth', payload: {'grant': 'forged'})),
          StoreAcl.denyBadOp);
      expect(
          acl(StoreFrame(op: 'import.begin', payload: {})),
          StoreAcl.denyBadOp);
    });

    test('非法 space 拒绝', () {
      expect(
          acl(StoreFrame(
              op: StoreOp.list, payload: {'space': 'system32'})),
          StoreAcl.denyBadOp);
    });
  });
}

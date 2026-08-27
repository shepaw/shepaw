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
            {String trust = TrustLevel.owner,
            bool loopback = false,
            bool Function(String space, String? path)? shareAllowed}) =>
        checkStoreAcl(f,
            callerDeviceId: caller,
            trustLevel: trust,
            loopback: loopback,
            shareAllowed: shareAllowed);

    test('friend 级管理/同步类拒绝；读未分享跨端拒绝', () {
      for (final op in [
        StoreOp.stats,
        StoreOp.search,
        StoreOp.eventsList,
        StoreOp.recycleList,
        StoreOp.recycleEmpty,
        StoreOp.syncHello,
      ]) {
        final v = acl(
            StoreFrame(op: op, payload: {'space': 'artifacts', 'q': 'x', 'device': caller}),
            trust: TrustLevel.friend);
        expect(v, StoreAcl.denyUntrusted, reason: 'op=$op');
      }
      // 跨端共享分区无白名单 → acl_denied
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'docs/a.txt',
                  }),
              trust: TrustLevel.friend),
          StoreAcl.denyAcl);
      // 自有目录读写允许
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.writeBegin,
                  payload: {'space': 'files', 'path': 'x', 'device': caller}),
              trust: TrustLevel.friend),
          StoreAcl.allow);
    });

    test('friend 白名单放行跨端共享分区', () {
      bool allowDocs(String space, String? path) {
        if (space != 'files') return false;
        final p = path ?? '';
        return p.isEmpty || p == 'docs' || p.startsWith('docs/');
      }

      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'docs/a.txt',
                  }),
              trust: TrustLevel.friend,
              shareAllowed: allowDocs),
          StoreAcl.allow);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'secret/a.txt',
                  }),
              trust: TrustLevel.friend,
              shareAllowed: allowDocs),
          StoreAcl.denyAcl);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.list,
                  payload: {'space': 'artifacts', 'device': other}),
              trust: TrustLevel.friend,
              shareAllowed: allowDocs),
          StoreAcl.denyAcl);
    });

    test('owner 白名单可收窄跨端共享分区', () {
      bool onlyArtifacts(String space, String? path) => space == 'artifacts';
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'x',
                  }),
              shareAllowed: onlyArtifacts),
          StoreAcl.denyAcl);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'artifacts',
                    'device': other,
                    'path': 'x',
                  }),
              shareAllowed: onlyArtifacts),
          StoreAcl.allow);
    });

    test('friend 分享白名单只读，不能 delete 他端', () {
      bool allowDocs(String space, String? path) {
        if (space != 'files') return false;
        final p = path ?? '';
        return p.isEmpty || p == 'docs' || p.startsWith('docs/');
      }

      expect(
          acl(
              StoreFrame(
                  op: StoreOp.read,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'docs/a.txt',
                  }),
              trust: TrustLevel.friend,
              shareAllowed: allowDocs),
          StoreAcl.allow);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.delete,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'docs/a.txt',
                  }),
              trust: TrustLevel.friend,
              shareAllowed: allowDocs),
          StoreAcl.denyAcl);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.delete,
                  payload: {
                    'space': 'files',
                    'device': other,
                    'path': 'docs/a.txt',
                  }),
              shareAllowed: allowDocs),
          StoreAcl.allow);
      expect(
          acl(
              StoreFrame(
                  op: StoreOp.delete,
                  payload: {
                    'space': 'files',
                    'device': caller,
                    'path': 'docs/a.txt',
                  }),
              trust: TrustLevel.friend),
          StoreAcl.allow);
    });

    test('workspaces：owner 可跨 device 写；runtime 不可', () {
      expect(
        acl(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': StoreSpace.workspaces,
            'device': other,
            'path': 'ws1/a.txt',
          },
        )),
        StoreAcl.allow,
      );
      expect(
        acl(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': StoreSpace.workspaces,
            'device': other,
            'path': 'ws1/a.txt',
          },
        ),
            trust: TrustLevel.friend),
        StoreAcl.denyAcl,
      );
      expect(
        acl(StoreFrame(
          op: StoreOp.writeBegin,
          payload: {
            'space': StoreSpace.runtime,
            'device': other,
            'path': 'a1/soul.md',
          },
        )),
        StoreAcl.denyAcl,
      );
      expect(
        acl(StoreFrame(
          op: StoreOp.list,
          payload: {
            'space': StoreSpace.runtime,
            'device': other,
          },
        )),
        StoreAcl.denyAcl,
      );
    });

    test('acl_cases.json fixture（含 workspaces 跨写）', () {
      final file = File('docs/storage_fixtures/acl_cases.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final cases = (json['cases'] as List).cast<Map<String, dynamic>>();
      final callerId = json['caller'] as String;
      for (final c in cases) {
        final frame = StoreFrame(
          op: c['op'] as String,
          payload: Map<String, dynamic>.from(c['payload'] as Map? ?? {}),
        );
        final v = checkStoreAcl(
          frame,
          callerDeviceId: callerId,
          trustLevel: c['trust'] as String,
          loopback: c['loopback'] as bool? ?? false,
        );
        final expectName = c['expect'] as String;
        final expected = switch (expectName) {
          'allow' => StoreAcl.allow,
          'denyAcl' => StoreAcl.denyAcl,
          'denyUntrusted' => StoreAcl.denyUntrusted,
          'denyBadOp' => StoreAcl.denyBadOp,
          _ => throw StateError('unknown expect $expectName'),
        };
        expect(v, expected, reason: c['name'] as String);
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
      // 读他端 artifacts/files → 允许（无白名单时 owner 兼容）
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
      // 删除他端共享分区 → owner 允许（friend 分享只读，见上一用例）
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

  group('store URI 与版本引用（spec §1.5，v4.2）', () {
    test('parseStoreUri 基本形态', () {
      final u = parseStoreUri(
          'store://artifacts/aaaaaaaaaaaaaaaa/task-1/out.txt@v3');
      expect(u.space, 'artifacts');
      expect(u.device, 'aaaaaaaaaaaaaaaa');
      expect(u.path, 'task-1/out.txt');
      expect(u.ref.kind, StoreUriRefKind.seq);
      expect(u.ref.value, 3);
      expect(
          storeUriWithRef('artifacts', 'aaaaaaaaaaaaaaaa', 'a.txt',
              const StoreUriRef.seq(2)),
          'store://artifacts/aaaaaaaaaaaaaaaa/a.txt@v2');
      expect(
        formatStoreMarkdownLink(
          'report.md',
          'store://runtime/aaaaaaaaaaaaaaaa/a/b/artifacts/t/report.md',
        ),
        '[report.md](store://runtime/aaaaaaaaaaaaaaaa/a/b/artifacts/t/report.md)',
      );
      // 文件名里的 @ 不误伤（后缀非引用形态）。
      expect(
          parseStoreUri('store://files/aaaaaaaaaaaaaaaa/contact@home.txt').path,
          'contact@home.txt');
      final root = parseStoreUri(
          'store://workspaces/aaaaaaaaaaaaaaaa',
          allowEmptyPath: true);
      expect(root.space, 'workspaces');
      expect(root.device, 'aaaaaaaaaaaaaaaa');
      expect(root.path, isEmpty);
      expect(
        () => parseStoreUri('store://workspaces/aaaaaaaaaaaaaaaa'),
        throwsFormatException,
      );
    });

    test('parseStoreUri 解码 Markdown 百分号编码的中文路径', () {
      const encoded =
          'store://artifacts/352821253aefdfba/general/%E6%95%B0%E7%8B%AC%E5%B0%8F%E6%B8%B8%E6%88%8F%E8%AE%BE%E8%AE%A1%E6%96%87%E6%A1%A3.md';
      const raw =
          'store://artifacts/352821253aefdfba/general/数独小游戏设计文档.md';
      final fromEncoded = parseStoreUri(encoded);
      final fromRaw = parseStoreUri(raw);
      expect(fromEncoded.path, 'general/数独小游戏设计文档.md');
      expect(fromRaw.path, 'general/数独小游戏设计文档.md');
      expect(fromEncoded.device, '352821253aefdfba');
    });

    test('version_cases fixture（共享契约，parse 层）', () {
      final file = File('docs/storage_fixtures/version_cases.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final c in (json['cases'] as List).cast<Map<String, dynamic>>()) {
        final name = c['name'] as String;
        final uri = c['uri'] as String;
        final expected = c['expect'] as String;
        try {
          final u = parseStoreUri(uri);
          expect(['ok', 'ambiguous_ref', 'not_found'], contains(expected),
              reason: '$name should not parse');
          if (expected == 'ok') {
            expect(u.space, c['space'], reason: name);
            expect(u.device, c['device'], reason: name);
            expect(u.path, c['path'], reason: name);
            final kind = c['ref_kind'] as String;
            if (kind == 'latest') {
              expect(u.ref.isLatest, isTrue, reason: name);
            } else if (kind == 'hash') {
              expect(u.ref.kind, StoreUriRefKind.hash, reason: name);
            } else {
              expect(u.ref.kind, StoreUriRefKind.seq, reason: name);
            }
          }
        } on FormatException {
          expect('bad_uri', expected, reason: name);
        } on BadPathException {
          expect('bad_path', expected, reason: name);
        }
      }
    });

    test('handoff_cases fixture（ACL 契约，spec §2.9）', () {
      const caller = 'aaaaaaaaaaaaaaaa';
      final file = File('docs/storage_fixtures/handoff_cases.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final c in (json['cases'] as List).cast<Map<String, dynamic>>()) {
        final frame = StoreFrame(
            op: c['op'] as String,
            payload: (c['payload'] as Map).cast<String, dynamic>());
        final v = checkStoreAcl(frame,
            callerDeviceId: caller,
            trustLevel: c['trust'] as String,
            loopback: c['loopback'] as bool? ?? false);
        expect(v.name, c['expect'], reason: c['name'] as String);
      }
    });

    test('space_profile_cases fixture（属性驱动 ACL，v4.3 Step 2）', () {
      const caller = 'aaaaaaaaaaaaaaaa';
      final file = File('docs/storage_fixtures/space_profile_cases.json');
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final known = (json['known'] as Map).cast<String, dynamic>();
      bool? vis(String space) {
        final v = known[space];
        if (v == null) return null;
        return v == 'shared';
      }

      for (final c in (json['cases'] as List).cast<Map<String, dynamic>>()) {
        final frame = StoreFrame(
            op: c['op'] as String,
            payload: (c['payload'] as Map? ?? const {}).cast<String, dynamic>());
        final v = checkStoreAclWith(frame,
            callerDeviceId: caller,
            trustLevel: c['trust'] as String,
            loopback: c['loopback'] as bool? ?? false,
            visibility: vis);
        expect(v.name, c['expect'], reason: c['name'] as String);
      }
    });
  });
}

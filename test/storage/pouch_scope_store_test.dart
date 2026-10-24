import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

class _FakeTransport implements PouchScopeTransport {
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  List<StoreEntry> entries = const <StoreEntry>[];
  /// 第一页之后还有没有下一页。
  String? firstNext;
  /// 按 cursor 预置的后续页；没有就是空页（到底）。
  Map<String, ({List<StoreEntry> entries, String? next})> pages =
      <String, ({List<StoreEntry> entries, String? next})>{};
  Uint8List? bytes;
  Map<String, dynamic>? failure;

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'list',
      'pouch_id': pouchId,
      'scope': scope.id,
      'prefix': prefix,
      'limit': limit,
      'cursor': cursor,
    });
    if (cursor == null) {
      return PouchListPage(entries: entries, nextCursor: firstNext);
    }
    final page = pages[cursor];
    return PouchListPage(
      entries: page?.entries ?? const <StoreEntry>[],
      nextCursor: page?.next,
    );
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'read',
      'pouch_id': pouchId,
      'scope': scope.id,
      'path': path,
    });
    return bytes;
  }

  List<String> scopeIds = const <String>[];
  PouchFileMeta? metaEntry;

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'scopes',
      'pouch_id': pouchId,
      'prefix': prefix,
    });
    return scopeIds;
  }

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'meta',
      'pouch_id': pouchId,
      'scope': scope.id,
      'path': path,
    });
    return metaEntry;
  }

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'write',
      'pouch_id': pouchId,
      'scope': scope.id,
      'path': path,
      'size': bytes.length,
      'expected_version': expectedVersion,
    });
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'delete',
      'pouch_id': pouchId,
      'scope': scope.id,
      'path': path,
    });
  }
}

StoreEntry _entry(String path, {int size = 1, int mtime = 0}) => StoreEntry(
      path: path,
      size: size,
      sha256: '',
      mtimeMs: mtime,
    );

void main() {
  test('扁平列表折成当前这一层：目录在前，深层条目归到目录里', () {
    final folded = foldScopeListing(
      [
        _entry('docs/a.md', mtime: 5),
        _entry('docs/sub/b.md', mtime: 9),
        _entry('z.md'),
        _entry('other/x.md'),
      ],
      path: 'docs',
    );
    expect(folded.map((e) => e.path).toList(), ['docs/sub', 'docs/a.md']);
    expect(folded.first.isDir, isTrue);
    expect(folded.first.mtimeMs, 9);
  });

  test('根上的折叠同样按目录优先排序', () {
    final folded = foldScopeListing([
      _entry('b.md'),
      _entry('a/c.md'),
      _entry('a.md'),
    ]);
    expect(folded.map((e) => e.path).toList(), ['a', 'a.md', 'b.md']);
  });

  test('listChildren 按 scope 取，只把 prefix 交出去', () async {
    final transport = _FakeTransport()
      ..entries = [_entry('docs/a.md'), _entry('docs/sub/b.md')];
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    final entries = await store.listChildren(
      PouchScope.groupSession('g1', 's1'),
      path: 'docs',
    );
    expect(transport.calls.single['pouch_id'], 'p1');
    expect(transport.calls.single['scope'], 'group:g1:session:s1');
    expect(transport.calls.single['prefix'], 'docs');
    expect(entries.map((e) => e.path).toList(), ['docs/sub', 'docs/a.md']);
  });

  test('listChildren 跟着 next_cursor 翻完所有页', () async {
    final transport = _FakeTransport()
      ..entries = [_entry('a/1.md')]
      ..firstNext = 'a/1.md'
      ..pages = {
        'a/1.md': (entries: [_entry('b/2.md')], next: null),
      };
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    final entries = await store.listChildren(PouchScope.files);
    expect(entries.map((e) => e.path).toList(), ['a', 'b']);
    expect(
      transport.calls.map((call) => call['cursor']).toList(),
      [null, 'a/1.md'],
    );
    expect(transport.calls.first['limit'], 1000);
  });

  test('写文件返回编码过的 v3 地址，路径先规范化', () async {
    final transport = _FakeTransport();
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    final uri = await store.write(
      PouchScope.groupSession('g1', 's1'),
      '/attachments/中文 名.png',
      Uint8List.fromList([1, 2, 3]),
    );
    expect(transport.calls.single['path'], 'attachments/中文 名.png');
    expect(
      uri,
      'pouch://p1/group:g1:session:s1/'
      'attachments/%E4%B8%AD%E6%96%87%20%E5%90%8D.png',
    );
    expect(PouchV2Uri.tryParse(uri)?.path, 'attachments/中文 名.png');
  });

  test('scopes 走 op=scopes：不带 scope 字段，前缀原样发出去', () async {
    final frame = pouchRequestFrame(
      op: StoreOp.scopes,
      reqId: 'r1',
      pouchId: 'p1',
      fields: <String, dynamic>{'prefix': 'slip:'},
    );
    expect(frame.containsKey('scope'), isFalse);
    expect(frame['op'], 'scopes');
    expect(frame['pouch_id'], 'p1');
    expect(frame['prefix'], 'slip:');
    expect(frame['v'], 2);

    final transport = _FakeTransport()..scopeIds = ['slip:sl_1', 'slip:sl_2'];
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    expect(await store.scopes('slip:'), ['slip:sl_1', 'slip:sl_2']);
    expect(transport.calls.single['op'], 'scopes');
    expect(transport.calls.single['prefix'], 'slip:');
    expect(transport.calls.single.containsKey('scope'), isFalse);
  });

  test('空 scope 名单不是错误：返回空列表', () async {
    final transport = _FakeTransport()..scopeIds = const <String>[];
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    expect(await store.scopes('skill:'), isEmpty);
  });

  test('写入带上读到的版本号（读–改–写）', () async {
    final transport = _FakeTransport();
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    await store.write(
      PouchScope.slip('sl_1'),
      'slip.json',
      Uint8List.fromList([1]),
      expectedVersion: 7,
    );
    expect(transport.calls.single['expected_version'], 7);
  });

  test('meta 把版本号带出来；不存在返回 null', () async {
    final transport = _FakeTransport()
      ..metaEntry = const PouchFileMeta(
        path: 'slip.json',
        size: 3,
        version: 4,
        mtimeMs: 99,
      );
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    final meta = await store.meta(PouchScope.slip('sl_1'), 'slip.json');
    expect(meta?.version, 4);
    expect(meta?.size, 3);
    expect(transport.calls.single['op'], 'meta');

    final missing = _FakeTransport();
    final emptyStore = PouchScopeStore(transport: missing, pouchId: 'p1');
    expect(await emptyStore.meta(PouchScope.slip('sl_1'), 'slip.json'), isNull);
  });

  test('读不到返回 null；删除也走同一个 pouch 与 scope', () async {
    final transport = _FakeTransport();
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    expect(await store.read(PouchScope.files, 'a.md'), isNull);
    await store.delete(PouchScope.files, '/a.md');
    expect(transport.calls.last['op'], 'delete');
    expect(transport.calls.last['path'], 'a.md');
  });
}

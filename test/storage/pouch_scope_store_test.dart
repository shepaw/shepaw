import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';

class _FakeTransport implements PouchScopeTransport {
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];
  List<StoreEntry> entries = const <StoreEntry>[];
  Uint8List? bytes;
  Map<String, dynamic>? failure;

  @override
  Future<List<StoreEntry>> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'list',
      'pouch_id': pouchId,
      'scope': scope.id,
      'prefix': prefix,
    });
    return entries;
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

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
  }) async {
    calls.add(<String, dynamic>{
      'op': 'write',
      'pouch_id': pouchId,
      'scope': scope.id,
      'path': path,
      'size': bytes.length,
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

  test('读不到返回 null；删除也走同一个 pouch 与 scope', () async {
    final transport = _FakeTransport();
    final store = PouchScopeStore(transport: transport, pouchId: 'p1');
    expect(await store.read(PouchScope.files, 'a.md'), isNull);
    await store.delete(PouchScope.files, '/a.md');
    expect(transport.calls.last['op'], 'delete');
    expect(transport.calls.last['path'], 'a.md');
  });
}

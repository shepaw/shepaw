import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/group_shared_files.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';

class _MemoryTransport implements PouchScopeTransport {
  final Map<String, Map<String, Uint8List>> files =
      <String, Map<String, Uint8List>>{};
  final Map<String, Map<String, int>> versions = <String, Map<String, int>>{};
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];

  Map<String, Uint8List> _scope(String id) =>
      files.putIfAbsent(id, () => <String, Uint8List>{});

  Map<String, int> _version(String id) =>
      versions.putIfAbsent(id, () => <String, int>{});

  @override
  Future<List<String>> scopes({
    required String pouchId,
    required String prefix,
  }) async =>
      const <String>[];

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    final bytes = _scope(scope.id)[path];
    if (bytes == null) return null;
    return PouchFileMeta(
      path: path,
      size: bytes.length,
      version: _version(scope.id)[path] ?? 1,
      mtimeMs: 0,
    );
  }

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async {
    calls.add(<String, dynamic>{'op': 'list', 'scope': scope.id, 'prefix': prefix});
    final entries = <StoreEntry>[
      for (final path in (_scope(scope.id).keys.toList()..sort()))
        if ((prefix ?? '').isEmpty || path.startsWith(prefix!))
          StoreEntry(
            path: path,
            size: _scope(scope.id)[path]!.length,
            sha256: '',
            mtimeMs: 0,
          ),
    ];
    return PouchListPage(entries: entries);
  }

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{'op': 'read', 'scope': scope.id, 'path': path});
    return _scope(scope.id)[path];
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
      'scope': scope.id,
      'path': path,
      'expected_version': expectedVersion,
    });
    _scope(scope.id)[path] = bytes;
    _version(scope.id)[path] = (_version(scope.id)[path] ?? 0) + 1;
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{'op': 'delete', 'scope': scope.id, 'path': path});
    _scope(scope.id).remove(path);
  }
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('共享文件落在 group:<gid>:shared/files 下', () async {
    final transport = _MemoryTransport();
    final shared = GroupSharedFiles(
      scopes: PouchScopeStore(transport: transport, pouchId: 'p1'),
    );

    final uri = await shared.write('group_a', '/docs/a.md', _bytes('hi'));
    expect(uri, 'pouch://p1/group:group_a:shared/files/docs/a.md');
    expect(transport.calls.last['scope'], 'group:group_a:shared');
    expect(transport.calls.last['path'], 'files/docs/a.md');

    expect(utf8.decode((await shared.read('group_a', 'docs/a.md'))!), 'hi');
    expect(transport.calls.last['path'], 'files/docs/a.md');

    await shared.delete('group_a', 'docs/a.md');
    expect(transport.calls.last['path'], 'files/docs/a.md');
    expect(await shared.read('group_a', 'docs/a.md'), isNull);
  });

  test('列一层时去掉 files/ 前缀，只给共享根之下的相对路径', () async {
    final transport = _MemoryTransport();
    transport.files['group:group_a:shared'] = <String, Uint8List>{
      'files/a.md': _bytes('a'),
      'files/docs/b.md': _bytes('bb'),
    };
    final shared = GroupSharedFiles(
      scopes: PouchScopeStore(transport: transport, pouchId: 'p1'),
    );
    final entries = await shared.list('group_a');
    // 目录在前（foldScopeListing 的排序）。
    expect(entries.map((e) => e.path).toList(), ['docs', 'a.md']);

    final nested = await shared.list('group_a', path: 'docs');
    expect(nested.map((e) => e.path).toList(), ['docs/b.md']);
  });

  test('共享目录按群取：scope 里没有 session 段', () async {
    final transport = _MemoryTransport();
    final shared = GroupSharedFiles(
      scopes: PouchScopeStore(transport: transport, pouchId: 'p1'),
    );
    // 同一个群，无论这一端切到哪条会话，共享面都是 group:<gid>:shared。
    await shared.write('group_a', 'a.md', _bytes('1'));
    await shared.write('group_a', 'b.md', _bytes('2'));
    final scopes = transport.calls
        .map((call) => call['scope'] as String)
        .toSet();
    expect(scopes, {'group:group_a:shared'});
    expect(scopes.any((id) => id.contains(':session:')), isFalse);
  });

  test('已经带了 files/ 的路径不会叠成 files/files', () async {
    final transport = _MemoryTransport();
    final shared = GroupSharedFiles(
      scopes: PouchScopeStore(transport: transport, pouchId: 'p1'),
    );
    await shared.write('group_a', 'files/a.md', _bytes('x'));
    expect(transport.calls.last['path'], 'files/a.md');
    await shared.list('group_a', path: 'files/docs');
    expect(transport.calls.last['prefix'], 'files/docs');
  });
}
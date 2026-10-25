import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/slip_scope_documents.dart';
import 'package:shepaw/storage/store_protocol.dart';

/// 内存版 v3 袋子：按 scope + path 存字节，版本号每次写 +1。
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
  }) async {
    calls.add(<String, dynamic>{'op': 'scopes', 'prefix': prefix});
    return <String>[
      for (final id in files.keys)
        if (id.startsWith(prefix)) id,
    ]..sort();
  }

  @override
  Future<PouchFileMeta?> meta({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{'op': 'meta', 'scope': scope.id, 'path': path});
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
    final all = _scope(scope.id).keys.toList()..sort();
    final entries = <StoreEntry>[
      for (final path in all)
        if (prefix == null || prefix.isEmpty || path.startsWith(prefix))
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
    final current = _version(scope.id)[path];
    if (expectedVersion != null && expectedVersion != current) {
      throw StoreException(StoreError.versionConflict, 'version_conflict');
    }
    _scope(scope.id)[path] = bytes;
    _version(scope.id)[path] = (current ?? 0) + 1;
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {
    calls.add(<String, dynamic>{'op': 'delete', 'scope': scope.id, 'path': path});
    _scope(scope.id).remove(path);
    _version(scope.id).remove(path);
  }
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

SlipScopeDocuments _docs(_MemoryTransport transport) => SlipScopeDocuments(
      store: PouchScopeStore(transport: transport, pouchId: 'p1'),
      deviceId: 'host-1',
    );

void main() {
  test('列表按 slip: 前缀列 scope，再读每条记录', () async {
    final transport = _MemoryTransport();
    transport.files['slip:sl_1'] = <String, Uint8List>{'slip.json': _bytes('{"a":1}')};
    transport.files['slip:sl_2'] = <String, Uint8List>{'slip.json': _bytes('{}')};
    final docs = _docs(transport);

    final entries = await docs.list(StoreSpace.slips);
    expect(entries.map((e) => e.path).toList(), ['sl_1.json', 'sl_2.json']);
    expect(entries.first.size, 7);
    expect(transport.calls.first['op'], 'scopes');
    expect(transport.calls.first['prefix'], 'slip:');

    // 紧接着的 read 用列表时留下的缓存，不再走一趟帧。
    final before = transport.calls.length;
    final bytes = await docs.read(StoreSpace.slips, 'sl_1.json');
    expect(utf8.decode(bytes!), '{"a":1}');
    expect(transport.calls.length, before);
  });

  test('记录与附件映射到 slip:<id> 的两个路径', () async {
    final transport = _MemoryTransport();
    final docs = _docs(transport);

    await docs.writeBytes(StoreSpace.slips, 'sl_9.json', _bytes('doc'));
    expect(transport.calls.last['scope'], 'slip:sl_9');
    expect(transport.calls.last['path'], 'slip.json');
    // 新建：没有 meta，不带 expected_version。
    expect(transport.calls.last['expected_version'], isNull);

    await docs.writeBytes(StoreSpace.slips, 'sl_9/files/a.txt', _bytes('att'));
    expect(transport.calls.last['scope'], 'slip:sl_9');
    expect(transport.calls.last['path'], 'files/a.txt');

    // 覆盖写：带上刚读到的版本号（这里 meta 走的是记录自己的版本）。
    await docs.writeBytes(StoreSpace.slips, 'sl_9/files/a.txt', _bytes('att2'));
    expect(transport.calls.last['expected_version'], 1);

    expect(
      await docs.read(StoreSpace.slips, 'sl_9/files/a.txt'),
      _bytes('att2'),
    );
    expect(await docs.read(StoreSpace.slips, 'sl_9/files/missing.txt'), isNull);
  });

  test('地址是 v3 三段式：记录与附件两个形状', () {
    final transport = _MemoryTransport();
    final docs = _docs(transport);
    expect(
      docs.uri(StoreSpace.slips, 'sl_1.json'),
      'pouch://p1/slip:sl_1/slip.json',
    );
    expect(
      docs.uri(StoreSpace.slips, 'sl_1/files/a b.txt'),
      'pouch://p1/slip:sl_1/files/a%20b.txt',
    );
  });

  test('删除记录走 scope 的 slip.json', () async {
    final transport = _MemoryTransport();
    transport.files['slip:sl_1'] = <String, Uint8List>{'slip.json': _bytes('{}')};
    final docs = _docs(transport);
    await docs.delete(StoreSpace.slips, 'sl_1.json');
    expect(transport.calls.last['op'], 'delete');
    expect(transport.calls.last['path'], 'slip.json');
    expect(transport.files['slip:sl_1'], isEmpty);
  });

  test('只处理 slips 分区', () {
    final docs = _docs(_MemoryTransport());
    expect(() => docs.uri(StoreSpace.workspaces, 'g1/a.md'), throwsArgumentError);
  });
}
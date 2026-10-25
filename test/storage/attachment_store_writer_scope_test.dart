import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/attachment_store_writer.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';

class _FakeScopeTransport implements PouchScopeTransport {
  final writes = <({String scope, String path, Uint8List bytes})>[];
  PouchFileMeta? metaEntry;

  @override
  Future<PouchListPage> list({
    required String pouchId,
    required PouchScope scope,
    String? prefix,
    int limit = 1000,
    String? cursor,
  }) async =>
      const PouchListPage(entries: <StoreEntry>[]);

  @override
  Future<Uint8List?> read({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async =>
      null;

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
  }) async =>
      metaEntry;

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    writes.add((scope: scope.id, path: path, bytes: bytes));
  }

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {}
}

void main() {
  const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
  late _FakeScopeTransport transport;
  late PouchScopeStore store;

  setUp(() {
    transport = _FakeScopeTransport();
    store = PouchScopeStore(transport: transport, pouchId: pouchId);
  });

  test('按内容 hash 写进 scope，返回 v3 地址', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    final hash = crypto.sha256.convert(bytes).toString();

    final uri = await AttachmentStoreWriter.storeScopedBytes(
      bytes,
      scope: PouchScope.agent('a1'),
      directory: 'files/attachments',
      store: store,
    );

    expect(
      uri,
      'pouch://$pouchId/agent:a1/files/attachments/$hash',
    );
    expect(transport.writes, hasLength(1));
    expect(transport.writes.single.scope, 'agent:a1');
    expect(transport.writes.single.path, 'files/attachments/$hash');
    expect(transport.writes.single.bytes, bytes);
  });

  test('目标目录带前导/尾随斜杠时归一化', () async {
    final bytes = Uint8List.fromList([9]);
    final hash = crypto.sha256.convert(bytes).toString();

    await AttachmentStoreWriter.storeScopedBytes(
      bytes,
      scope: PouchScope.groupSession('g1', 's1'),
      directory: '/attachments/m1/',
      store: store,
    );

    expect(
      transport.writes.single.path,
      'attachments/m1/$hash',
    );
  });

  test('同一份内容已经在盘上时不再写', () async {
    final bytes = Uint8List.fromList([1]);
    final hash = crypto.sha256.convert(bytes).toString();
    transport.metaEntry = PouchFileMeta(
      path: 'attachments/m1/$hash',
      size: bytes.length,
      version: 1,
      mtimeMs: 0,
    );

    final uri = await AttachmentStoreWriter.storeScopedBytes(
      bytes,
      scope: PouchScope.groupSession('g1', 's1'),
      directory: 'attachments/m1',
      store: store,
    );

    expect(uri, 'pouch://$pouchId/group:g1:session:s1/attachments/m1/$hash');
    expect(transport.writes, isEmpty);
  });
}

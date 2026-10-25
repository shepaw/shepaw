import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/pending_attachment.dart';
import 'package:shepaw/models/store_attachment_ref.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_service.dart';

class _FakeScopeTransport implements PouchScopeTransport {
  Uint8List? bytes;
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
      bytes;

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
  }) async {}

  @override
  Future<void> delete({
    required String pouchId,
    required PouchScope scope,
    required String path,
  }) async {}
}

void main() {
  const pouchId = 'a95b5782-4d50-45d2-83e1-8e40954d1239';
  const groupId = '0d576a96-ac07-4c9f-a2c5-7c37f8db4987';
  late _FakeScopeTransport transport;

  setUp(() {
    transport = _FakeScopeTransport();
    StoreService.instance.scopeStoreOverride =
        PouchScopeStore(transport: transport, pouchId: pouchId);
    StoreService.instance.currentPouchIdOverride = pouchId;
  });

  tearDown(() {
    StoreService.instance.scopeStoreOverride = null;
    StoreService.instance.currentPouchIdOverride = null;
  });

  test('v3 袋子引用能物化成待发送附件', () async {
    final payload = Uint8List.fromList([1, 2, 3, 4]);
    transport.bytes = payload;
    transport.metaEntry = const PouchFileMeta(
      path: 'files/report.bin',
      size: 4,
      version: 1,
      mtimeMs: 0,
    );
    final ref = StoreAttachmentRef.scoped(
      pouchId: pouchId,
      scope: PouchScope.groupShared(groupId).id,
      path: 'files/report.bin',
      displayName: 'report.bin',
      sizeBytes: payload.length,
    );

    final pending = await PendingAttachment.fromStoreRef(ref);

    expect(pending, isNotNull);
    expect(await pending!.file.readAsBytes(), payload);
    expect(pending.fileName, 'report.bin');
    expect(pending.storeRef, same(ref));
    await pending.file.parent.delete(recursive: true);
  });
}

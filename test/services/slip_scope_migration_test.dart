import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/slip_scope_migration.dart';
import 'package:shepaw/storage/local_store.dart';
import 'package:shepaw/storage/pouch_scope.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_protocol.dart';
import 'package:shepaw/storage/store_service.dart';

import '../storage/test_harness.dart';

class _FakeScopeTransport implements PouchScopeTransport {
  _FakeScopeTransport({this.offline = false});

  final bool offline;
  final writes = <({String scope, String path, Uint8List bytes})>[];
  final existing = <String>{};

  void _guard() {
    if (offline) {
      throw StoreException(StoreError.masterOffline, '主机不在线');
    }
  }

  String _key(PouchScope scope, String path) => '${scope.id}/$path';

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
  }) async {
    _guard();
    if (!existing.contains(_key(scope, path))) return null;
    return PouchFileMeta(path: path, size: 1, version: 1, mtimeMs: 0);
  }

  @override
  Future<void> write({
    required String pouchId,
    required PouchScope scope,
    required String path,
    required Uint8List bytes,
    int? expectedVersion,
  }) async {
    _guard();
    writes.add((scope: scope.id, path: path, bytes: bytes));
    existing.add(_key(scope, path));
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
  const device = 'aaaaaaaaaaaaaaaa';
  const slipId = 'sl_legacy1';
  late LocalStore store;
  late _FakeScopeTransport transport;
  String? marker;

  setUpAll(() async {
    await StorageTestHarness.init();
    await StoreService.instance.start();
  });

  setUp(() async {
    SlipScopeMigration.resetForTest();
    marker = null;
    transport = _FakeScopeTransport();
    StoreService.instance.scopeStoreOverride =
        PouchScopeStore(transport: transport, pouchId: pouchId);
    StoreService.instance.currentPouchIdOverride = pouchId;
    SlipScopeMigration.debugReadMarker = () async => marker;
    SlipScopeMigration.debugWriteMarker = (id) async => marker = id;

    store = await StoreService.instance.localStore();
    await store.putBytes(
      deviceId: device,
      space: StoreSpace.slips,
      path: '$slipId.json',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    await store.putBytes(
      deviceId: device,
      space: StoreSpace.slips,
      path: '$slipId/files/a.txt',
      bytes: Uint8List.fromList([9, 8]),
    );
  });

  tearDown(() async {
    StoreService.instance.scopeStoreOverride = null;
    StoreService.instance.currentPouchIdOverride = null;
    SlipScopeMigration.resetForTest();
    for (final path in ['$slipId.json', slipId]) {
      try {
        await store.delete(device, StoreSpace.slips, path);
      } on StoreException {
        // 已经不在了
      }
    }
  });

  test('v2 存量玉简补进 slip:<id>，记录和附件都搬', () async {
    await SlipScopeMigration.ensure();

    expect(transport.writes, hasLength(2));
    final record = transport.writes
        .firstWhere((w) => w.path == 'slip.json');
    expect(record.scope, 'slip:$slipId');
    expect(record.bytes, [1, 2, 3]);
    final attachment = transport.writes
        .firstWhere((w) => w.path == 'files/a.txt');
    expect(attachment.scope, 'slip:$slipId');
    expect(attachment.bytes, [9, 8]);
    expect(marker, pouchId);
  });

  test('host 上已有的记录/附件不覆盖', () async {
    transport.existing.addAll([
      'slip:$slipId/slip.json',
      'slip:$slipId/files/a.txt',
    ]);

    await SlipScopeMigration.ensure();

    expect(transport.writes, isEmpty);
  });

  test('按袋子记标记：同一只袋子第二次不再扫', () async {
    await SlipScopeMigration.ensure();
    expect(transport.writes, hasLength(2));

    // 模拟重启：内存状态清掉，标记还在。
    SlipScopeMigration.resetForTest();
    SlipScopeMigration.debugReadMarker = () async => marker;
    SlipScopeMigration.debugWriteMarker = (id) async => marker = id;
    await SlipScopeMigration.ensure();

    expect(transport.writes, hasLength(2));
  });

  test('主机不在线：不落标记，下次还能再试', () async {
    final offline = _FakeScopeTransport(offline: true);
    StoreService.instance.scopeStoreOverride =
        PouchScopeStore(transport: offline, pouchId: pouchId);

    await SlipScopeMigration.ensure();

    expect(offline.writes, isEmpty);
    expect(marker, isNull);
  });

  test('没有 v3 袋子时什么都不做', () async {
    StoreService.instance.scopeStoreOverride = null;
    StoreService.instance.currentPouchIdOverride = null;

    await SlipScopeMigration.ensure();

    expect(transport.writes, isEmpty);
    expect(marker, isNull);
  });
}

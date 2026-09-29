import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise_identity.dart';
import 'package:shepaw/storage/pouch_identity_store.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_identity_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('袋子里的记录优先于钥匙串', () {
    final decided = PouchIdentityAdoption.decide(
      pouchRecord: 'v1.pouch',
      keychainRecord: 'v1.keychain',
    );
    expect(decided.source, PouchIdentitySource.pouch);
    expect(decided.record, 'v1.pouch');
  });

  test('袋子是空的时种进钥匙串里的记录', () {
    final decided = PouchIdentityAdoption.decide(
      pouchRecord: '  ',
      keychainRecord: 'v1.keychain',
    );
    expect(decided.source, PouchIdentitySource.keychain);
    expect(decided.record, 'v1.keychain');
  });

  test('两边都没有时不生成记录', () {
    final decided = PouchIdentityAdoption.decide();
    expect(decided.source, PouchIdentitySource.none);
    expect(decided.record, isNull);
  });

  test('合法记录可以写入并读回', () async {
    final id = NoiseIdentity.fromRawBytes(
      publicKey: Uint8List(32)..[0] = 1,
      privateKey: Uint8List(32)..[0] = 2,
      createdAtMs: 10,
    );
    final store = PouchIdentityStore(root);
    await store.writeRecord(id.encodeRecord());
    expect(await store.readRecord(), id.encodeRecord());
    expect(
      File('${root.path}/.system/${PouchIdentityStore.fileName}').existsSync(),
      isTrue,
    );
  });

  test('损坏的记录拒绝读出', () async {
    final store = PouchIdentityStore(root);
    await store.file.parent.create(recursive: true);
    await store.file.writeAsString('not-a-record');
    expect(store.readRecord(), throwsFormatException);
  });

  test('没有文件时返回 null', () async {
    expect(await PouchIdentityStore(root).readRecord(), isNull);
  });
}

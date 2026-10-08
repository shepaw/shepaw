import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/noise_identity.dart';
import 'package:shepaw/storage/pouch_catalog.dart';
import 'package:shepaw/storage/pouch_identity_store.dart';
import 'package:shepaw/storage/pouch_session.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_catalog_');
  });

  tearDown(() async {
    PouchSessionStore.debugResetCache();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('新建袋子各自带身份，列出来互不覆盖', () async {
    final catalog = PouchCatalog(root);
    final home = await catalog.create(name: '家里');
    final work = await catalog.create(name: '工作');

    final listed = await catalog.list();
    expect(listed.map((p) => p.name), ['家里', '工作']);
    expect(home.id, isNot(work.id));

    final homeRecord =
        await PouchIdentityStore(Directory(home.rootPath)).readRecord();
    final workRecord =
        await PouchIdentityStore(Directory(work.rootPath)).readRecord();
    expect(homeRecord, isNotNull);
    expect(workRecord, isNotNull);
    expect(
      NoiseIdentity.parseRecord(homeRecord!).fingerprintHex,
      isNot(NoiseIdentity.parseRecord(workRecord!).fingerprintHex),
    );
  });

  test('空名字不能建袋子', () async {
    expect(
      PouchCatalog(root).create(name: '  '),
      throwsArgumentError,
    );
  });

  test('登录记录缺主机时不算已登录', () async {
    final file = File('${root.path}/session.json');
    await file.writeAsString(
      '{"hub_url":"http://127.0.0.1:4000","pouch_id":"p1","pouch_name":"家里"}',
    );
    expect(await PouchSessionStore(file).load(), isNull);
  });

  test('登录记录能读回选中的袋子', () async {
    final file = File('${root.path}/session.json');
    const session = PouchSession(
      hubUrl: 'http://127.0.0.1:4000',
      pouchId: 'p1',
      pouchName: '家里',
      hostPeerId: 'peer-1',
    );
    await PouchSessionStore(file).save(session);
    final loaded = await PouchSessionStore(file).load();
    expect(loaded?.pouchId, 'p1');
    expect(loaded?.hostPeerId, 'peer-1');
  });

  test('readActive 复用内存里的登录态', () async {
    PouchSessionStore.debugResetCache();
    const session = PouchSession(
      hubUrl: 'http://127.0.0.1:4000',
      pouchId: 'p1',
      pouchName: '家里',
      hostPeerId: 'peer-1',
    );
    PouchSessionStore.remember(session);
    addTearDown(PouchSessionStore.debugResetCache);

    final read = await PouchSessionStore.readActive();
    expect(read?.hostPeerId, 'peer-1');
    expect(identical(read, session), isTrue);

    PouchSessionStore.remember(null);
    expect(await PouchSessionStore.readActive(), isNull);
  });
}

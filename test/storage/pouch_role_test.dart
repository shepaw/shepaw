import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/pouch_role.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_role_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('没有角色文件时在本机跑回合', () async {
    final role = await PouchRoleStore(root).load();
    expect(role.isHost, isTrue);
    expect(PouchTurnRoute.decide(role).runLocal, isTrue);
  });

  test('客户端把回合交给指定主机', () async {
    await PouchRoleStore(root).save(const PouchRole.client('peer-host'));
    final role = await PouchRoleStore(root).load();
    final route = PouchTurnRoute.decide(role);
    expect(route.runLocal, isFalse);
    expect(route.hostPeerId, 'peer-host');
  });

  test('客户端没有主机身份时拒绝在本地开跑', () {
    expect(
      () => PouchTurnRoute.decide(const PouchRole.client('  ')),
      throwsStateError,
    );
  });

  test('客户端必须写下主机', () async {
    expect(
      PouchRoleStore(root).save(const PouchRole.client('')),
      throwsArgumentError,
    );
  });
}

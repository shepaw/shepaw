import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/pouch_roster.dart';
import 'package:shepaw/storage/agent_roster.dart';
import 'package:shepaw/storage/pouch_role.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pouch_roster_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('本机路径头像不进卡，图片字节和工作区要', () {
    final reports = PouchRosterSync.reportsFromAgentList([
      {
        'id': 'remote-1',
        'name': 'Codex',
        'avatar': '/tmp/a.png',
        'engine': 'codex',
        'running': true,
        'workspace_uri': 'store://workspaces/x',
        'avatar_data': base64Encode([1, 2, 3]),
      },
      {'id': '  ', 'name': '空白'},
      {'name': '没有 id'},
      {
        'id': 'remote-2',
        'avatar': r'C:\a.png',
        'workspaceUri': 'file:///nope',
        'avatar_data': '不是 base64 !!!',
      },
    ]);

    expect(reports, hasLength(2));
    expect(reports[0].avatar, isEmpty);
    expect(reports[0].avatarBytes, [1, 2, 3]);
    expect(reports[0].workspaceUri, 'store://workspaces/x');
    expect(reports[0].running, isTrue);
    expect(reports[0].engine, 'codex');
    expect(reports[1].name, 'remote-2');
    expect(reports[1].avatar, isEmpty);
    expect(reports[1].workspaceUri, isNull);
    expect(reports[1].avatarBytes, isNull);
  });

  test('客户端不写名册，主机写入后卸掉只清拨号', () async {
    await PouchRoleStore(root).save(PouchRole.client('host-peer'));
    await PouchRosterSync.applyAgentList(
      root: root,
      hubFingerprint: 'hubaaaa',
      agents: const [
        {'id': 'a', 'name': 'A'},
      ],
    );
    expect(await AgentRosterStore(root).load(), isEmpty);

    await File(
      '${root.path}/.system/${PouchRoleStore.fileName}',
    ).delete();
    await PouchRosterSync.applyAgentList(
      root: root,
      hubFingerprint: 'hubaaaa',
      agents: const [
        {'id': 'a', 'name': 'A', 'avatar': '🦊'},
      ],
    );
    final written = await AgentRosterStore(root).load();
    expect(written, hasLength(1));
    expect(written.single.dialable, isTrue);
    expect(written.single.avatar, '🦊');
    expect(written.single.remoteAgentId, 'a');

    await PouchRoleStore(root).save(PouchRole.client('host-peer'));
    await PouchRosterSync.detachHub(
      root: root,
      hubFingerprint: 'hubaaaa',
    );
    expect((await AgentRosterStore(root).load()).single.dialable, isTrue);

    await File(
      '${root.path}/.system/${PouchRoleStore.fileName}',
    ).delete();
    await PouchRosterSync.detachHub(
      root: root,
      hubFingerprint: 'hubaaaa',
    );
    final left = (await AgentRosterStore(root).load()).single;
    expect(left.name, 'A');
    expect(left.dial, isNull);
    expect(left.hubFingerprint, 'hubaaaa');
  });
}

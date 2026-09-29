import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
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

  test('能拨的卡按指纹找设备，卸掉或对不上就停', () {
    final dialable = AgentRosterCard(
      id: 'card-a',
      name: 'Codex',
      avatar: '',
      engine: 'codex',
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
      dial: const AgentDial(running: true),
    );
    final detached = dialable.copyWith(clearDial: true);
    const peers = [(id: 'peer-9', fingerprint: 'hubaaaa')];

    final hit = PouchRosterDial.decide(
      cards: [dialable],
      peers: peers,
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
    );
    expect(hit.blocked, isFalse);
    expect(hit.peerId, 'peer-9');
    expect(hit.remoteAgentId, 'remote-1');

    expect(
      PouchRosterDial.decide(
        cards: [detached],
        peers: peers,
        hubFingerprint: 'hubaaaa',
        remoteAgentId: 'remote-1',
      ).blocked,
      isTrue,
    );
    expect(
      PouchRosterDial.decide(
        cards: [dialable],
        peers: const [(id: 'peer-9', fingerprint: 'other')],
        hubFingerprint: 'hubaaaa',
        remoteAgentId: 'remote-1',
      ).blocked,
      isTrue,
    );

    final missing = PouchRosterDial.decide(
      cards: [
        const AgentRosterCard(
          id: 'she',
          name: 'She',
          avatar: '',
          engine: 'she',
          boundToPouch: true,
        ),
      ],
      peers: peers,
      hubFingerprint: 'hubaaaa',
      remoteAgentId: 'remote-1',
    );
    expect(missing.blocked, isFalse);
    expect(missing.peerId, isNull);
  });

  test('客户端不返回名册，主机行 id 就是卡 id', () async {
    await PouchRoleStore(root).save(PouchRole.client('host-peer'));
    expect(
      await PouchRosterSync.applyIfHost(
        root: root,
        hubFingerprint: 'hubaaaa',
        agents: const [
          {'id': 'remote-1', 'name': 'Codex'},
        ],
      ),
      isNull,
    );

    await File('${root.path}/.system/${PouchRoleStore.fileName}').delete();
    final cards = await PouchRosterSync.applyIfHost(
      root: root,
      hubFingerprint: 'hubaaaa',
      agents: const [
        {'id': 'remote-1', 'name': 'Codex'},
      ],
    );
    expect(cards, isNotNull);
    final cardId = PouchRosterSync.cardIdFor(cards!, 'hubaaaa', 'remote-1');
    expect(cardId, isNotNull);

    await PouchRosterSync.detachHub(root: root, hubFingerprint: 'hubaaaa');
    final stopped = await PouchRosterDial.decideLive(
      fallbackPeerId: 'peer-old',
      remoteAgentId: 'remote-1',
      hubFingerprint: 'hubaaaa',
      root: root,
      peerById: (_) async => null,
      loadPeers: () async => const [],
    );
    expect(stopped.blocked, isTrue);

    await AgentRosterStore(root).applyHubList(
      hubFingerprint: 'hubaaaa',
      agents: const [
        HubAgentReport(remoteAgentId: 'remote-1', name: 'Codex', running: true),
      ],
    );
    final again = await PouchRosterDial.decideLive(
      fallbackPeerId: 'peer-old',
      remoteAgentId: 'remote-1',
      hubFingerprint: 'hubaaaa',
      root: root,
      peerById: (_) async => null,
      loadPeers: () async => [
        PairedPeer(
          id: 'peer-9',
          deviceName: 'hub',
          deviceId: 'dev',
          publicKey: Uint8List(32),
          fingerprint: 'hubaaaa',
          pairedAt: 1,
        ),
      ],
    );
    expect(again.peerId, 'peer-9');
    expect(
      (await AgentRosterStore(root).load()).single.id,
      cardId,
    );
  });
}

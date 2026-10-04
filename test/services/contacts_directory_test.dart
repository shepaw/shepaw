import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/agent.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/services/contacts_directory.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  PairedPeer peer(
    String id,
    String name,
    String fingerprint, {
    PeerConnectionState state = PeerConnectionState.disconnected,
  }) {
    return PairedPeer(
      id: id,
      deviceName: name,
      deviceId: id,
      publicKey: Uint8List(32),
      fingerprint: fingerprint,
      pairedAt: 0,
      state: state,
    );
  }

  Agent agent({
    required String id,
    required String name,
    String? sourcePeerId,
    String? sourcePeerName,
    String? rosterFingerprint,
    bool she = false,
    bool hidden = false,
  }) {
    return Agent(
      id: id,
      name: name,
      avatar: '🤖',
      metadata: {
        if (sourcePeerId != null) 'source_peer_id': sourcePeerId,
        if (sourcePeerName != null) 'source_peer_name': sourcePeerName,
        if (rosterFingerprint != null)
          'roster_hub_fingerprint': rosterFingerprint,
        if (she) 'is_she': true,
        if (hidden) 'hidden_on_this_app': true,
      },
      provider: const AgentProvider(name: '', platform: '', type: ''),
      status: const AgentStatus(state: 'online'),
    );
  }

  const hostId = 'host-peer';
  const hostFp = 'c1b74877debb2fd6';
  const appFp = 'aaaaaaaaaaaaaaaa';

  test('主机、工作设备和我的设备按指纹分组', () {
    final host = peer(hostId, 'EDENZOU-MB2', hostFp);
    final worker = peer(
      'worker-local',
      '公司 Mac mini',
      'bbbbbbbbbbbbbbbb',
      state: PeerConnectionState.connected,
    );
    final phone = peer('phone-local', 'Android-AA38', 'cccccccccccccccc');
    final mine = peer('app-local', 'EDENZOU-MB2', appFp);

    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: host,
      roster: [host, worker, phone, mine],
      agents: [
        agent(
          id: 'cli',
          name: 'shepaw-cli',
          sourcePeerId: hostId,
          rosterFingerprint: hostFp,
        ),
        agent(
          id: SheService.sheId,
          name: 'She',
          sourcePeerId: hostId,
          she: true,
        ),
        agent(
          id: 'remote-cli',
          name: 'Codex',
          sourcePeerId: 'some-other-local-id',
          rosterFingerprint: 'BBBBBBBBBBBBBBBB',
        ),
        agent(
          id: 'orphan',
          name: '迷路的',
          sourcePeerId: 'unknown-peer',
          rosterFingerprint: 'ffffffffffff',
        ),
        agent(
          id: 'hidden',
          name: '隐藏',
          sourcePeerId: hostId,
          hidden: true,
        ),
      ],
      appFingerprint: appFp,
      localCliFingerprint: hostFp,
      connectedPeerIds: {hostId},
      rosterFailed: false,
    );

    expect(view.hasSession, isTrue);
    expect(view.hostOnline, isTrue);
    expect(view.hostIsThisComputer, isTrue);
    expect(view.hostAgents.map((a) => a.id).toList(), [SheService.sheId, 'cli']);
    expect(view.otherAgents.map((a) => a.name), ['迷路的']);
    expect(view.workers.map((d) => d.peer.deviceName), ['公司 Mac mini']);
    expect(view.workers.single.agents.single.name, 'Codex');
    expect(view.workers.single.online, isTrue);
    expect(view.myDevices.map((d) => d.peer.deviceName),
        ['Android-AA38', 'EDENZOU-MB2']);
    expect(view.myDevices.last.isThisDevice, isTrue);
    expect(view.myDevices.first.isThisDevice, isFalse);
  });

  test('名单里等于主机指纹的项被去掉', () {
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, 'EDENZOU-MB2', 'C1B74877DEBB2FD6'),
      roster: [
        peer('echo', 'EDENZOU-MB2', 'c1b74877debb2fd6'),
        peer('phone', 'Android', 'dddddddddddddddd'),
      ],
      agents: const [],
      appFingerprint: null,
      localCliFingerprint: null,
      connectedPeerIds: {hostId},
      rosterFailed: false,
    );

    expect(view.workers, isEmpty);
    expect(view.myDevices.map((d) => d.peer.id), ['phone']);
  });

  test('没有登录态就没有主机节', () {
    final view = buildContacts(
      hostPeerId: null,
      hostPeer: null,
      roster: [peer('phone', 'Android', 'dddddddddddddddd')],
      agents: [
        agent(id: 'cli', name: 'shepaw-cli', sourcePeerId: hostId),
      ],
      appFingerprint: appFp,
      localCliFingerprint: null,
      connectedPeerIds: const {},
      rosterFailed: false,
    );

    expect(view.hasSession, isFalse);
    expect(view.host, isNull);
    expect(view.hostAgents, isEmpty);
    expect(view.workers, isEmpty);
  });

  test('主机不在连接集合里就是离线，名单失败单独标出', () {
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, 'EDENZOU-MB2', hostFp),
      roster: const [],
      agents: const [],
      appFingerprint: null,
      localCliFingerprint: null,
      connectedPeerIds: const {},
      rosterFailed: true,
    );

    expect(view.hostOnline, isFalse);
    expect(view.rosterFailed, isTrue);
    expect(view.hostIsThisComputer, isFalse);
  });
}

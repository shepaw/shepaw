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
    String? role,
    String? platform,
  }) {
    return PairedPeer(
      id: id,
      deviceName: name,
      deviceId: id,
      publicKey: Uint8List(32),
      fingerprint: fingerprint,
      pairedAt: 0,
      state: state,
      nodeRole: role,
      platform: platform,
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
    Map<String, dynamic> node = const {},
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
        ...node,
      },
      provider: const AgentProvider(name: '', platform: '', type: ''),
      status: const AgentStatus(state: 'online'),
    );
  }

  const hostId = 'host-peer';
  const hostFp = 'c1b74877debb2fd6';
  const appFp = 'aaaaaaaaaaaaaaaa';

  test('全部设备平铺，主机排在最前', () {
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
    expect(view.devices.map((d) => d.peer.deviceName), [
      'EDENZOU-MB2',
      '公司 Mac mini',
      'Android-AA38',
    ]);
    expect(view.devices.first.isHost, isTrue);
    expect(view.devices.first.isThisDevice, isTrue);
    expect(view.devices.first.agents.map((a) => a.id).toList(),
        [SheService.sheId, 'cli']);
    expect(view.otherAgents.map((a) => a.name), ['迷路的']);
    expect(view.devices[1].agents.single.name, 'Codex');
    expect(view.devices[1].online, isTrue);
    expect(view.devices[1].isHost, isFalse);
    expect(view.devices[1].isThisDevice, isFalse);
    expect(view.devices.last.isThisDevice, isFalse);
    expect(view.devices.last.isHost, isFalse);
  });

  test('主机就在这台电脑时，名单里的本机镜像并进主机行', () {
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, 'EDENZOU-MB2', hostFp),
      roster: [
        peer(
          hostId,
          'EDENZOU-MB2',
          appFp,
          state: PeerConnectionState.connected,
        ),
        peer('phone', 'Android-AA38', 'cccccccccccccccc'),
      ],
      agents: [
        agent(
          id: 'on-app',
          name: '挂在镜像上的',
          sourcePeerId: 'somewhere',
          rosterFingerprint: appFp,
        ),
      ],
      appFingerprint: appFp,
      localCliFingerprint: hostFp,
      connectedPeerIds: {hostId},
      rosterFailed: false,
    );

    expect(view.devices.map((d) => d.peer.id), [hostId, 'phone']);
    expect(view.devices.first.isHost, isTrue);
    expect(view.devices.first.isThisDevice, isTrue);
    expect(view.devices.first.agents.single.name, '挂在镜像上的');
    expect(view.devices.map((d) => d.rowKey).toSet().length, 2);
  });

  test('手机上看远程主机时，本机仍单独列出', () {
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, '家里的 Mac', hostFp),
      roster: [
        peer(
          hostId,
          'Android-AA38',
          appFp,
          state: PeerConnectionState.connected,
        ),
      ],
      agents: const [],
      appFingerprint: appFp,
      localCliFingerprint: null,
      connectedPeerIds: {hostId},
      rosterFailed: false,
    );

    expect(view.devices.map((d) => d.peer.deviceName), ['家里的 Mac', 'Android-AA38']);
    expect(view.devices.first.isHost, isTrue);
    expect(view.devices.first.isThisDevice, isFalse);
    expect(view.devices.last.isHost, isFalse);
    expect(view.devices.last.isThisDevice, isTrue);
    expect(view.devices.first.rowKey, isNot(view.devices.last.rowKey));
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

    expect(view.devices.map((d) => d.peer.id), [hostId, 'phone']);
    expect(view.devices.first.isHost, isTrue);
    expect(view.devices.last.isHost, isFalse);
  });

  test('没有登录态就没有设备', () {
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
    expect(view.devices, isEmpty);
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

  test('按身份分成主机、工作节点、PC 客户端、移动客户端', () {
    const nodeFp = 'eeeeeeeeeeeeeeee';
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, 'Hub', hostFp, role: 'host'),
      roster: [
        peer('gpu', 'gpu-box', 'EEEEEEEEEEEEEEEE',
            role: 'worker', state: PeerConnectionState.connected),
        peer('mac', 'MacBook', 'bbbbbbbbbbbbbbbb', role: 'client', platform: 'macos'),
        peer('phone', 'Pixel', 'cccccccccccccccc', role: 'client', platform: 'android'),
        peer('old', '旧手机', 'dddddddddddddddd', platform: 'ios'),
      ],
      agents: [
        agent(id: 'local', name: '主机上的', sourcePeerId: hostId),
        agent(
          id: 'remote',
          name: '节点上的',
          sourcePeerId: hostId,
          node: const {
            'node_id': nodeFp,
            'node_name': 'gpu-box',
            'node_role': 'worker',
            'online': true,
          },
        ),
      ],
      appFingerprint: 'bbbbbbbbbbbbbbbb',
      localCliFingerprint: null,
      connectedPeerIds: {hostId},
      rosterFailed: false,
    );

    List<String> names(ContactSection section) =>
        view.inSection(section).map((d) => d.peer.deviceName).toList();
    expect(names(ContactSection.host), ['Hub']);
    expect(names(ContactSection.worker), ['gpu-box']);
    expect(names(ContactSection.pcClient), ['MacBook']);
    expect(names(ContactSection.mobileClient), ['Pixel', '旧手机']);

    final host = view.inSection(ContactSection.host).single;
    expect(host.agents.map((a) => a.id), ['local']);
    expect(host.nodeId, isNull);
    final worker = view.inSection(ContactSection.worker).single;
    expect(worker.agents.map((a) => a.id), ['remote']);
    expect(worker.nodeId, nodeFp);
    expect(view.inSection(ContactSection.pcClient).single.isThisDevice, isTrue);
    expect(view.inSection(ContactSection.pcClient).single.agents, isEmpty);
  });

  test('名单里还没有的工作节点按 Agent 的节点信息补一行', () {
    final view = buildContacts(
      hostPeerId: hostId,
      hostPeer: peer(hostId, 'Hub', hostFp),
      roster: const [],
      agents: [
        agent(
          id: 'remote',
          name: '节点上的',
          sourcePeerId: hostId,
          node: const {
            'node_id': 'ffff000011112222',
            'node_name': 'nas',
            'online': false,
          },
        ),
      ],
      appFingerprint: null,
      localCliFingerprint: null,
      connectedPeerIds: {hostId},
      rosterFailed: true,
    );

    final worker = view.inSection(ContactSection.worker).single;
    expect(worker.peer.deviceName, 'nas');
    expect(worker.online, isFalse);
    expect(worker.nodeId, 'ffff000011112222');
    expect(view.devices.first.agents, isEmpty);
  });
}

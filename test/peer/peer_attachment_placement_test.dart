import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/models/paired_peer.dart';
import 'package:shepaw/peer/services/peer_agent_host_service.dart';
import 'package:shepaw/peer/services/peer_attachment_placement.dart';
import 'package:shepaw/peer/services/peer_storage_service.dart';

import '../storage/test_harness.dart';

RemoteAgent _peerAgent({
  required String id,
  required String peerId,
  required String remoteAgentId,
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: 'Peer A',
    token: '',
    endpoint: '',
    protocol: ProtocolType.peer,
    connectionType: ConnectionType.websocket,
    status: AgentStatus.online,
    capabilities: const [],
    metadata: {
      'source_peer_id': peerId,
      'remote_agent_id': remoteAgentId,
    },
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
  });

  test('resolvePeerAttachmentPlacement 对齐宿主 channel 与对端 fingerprint',
      () async {
    const peerId = 'pair-1';
    const remoteId = 'agent-a';
    const fp = 'aabbccddeeff0011';
    final storage = PeerStorageService();
    await storage.savePeer(PairedPeer(
      id: peerId,
      deviceName: 'Phone',
      deviceId: 'dev-uuid',
      publicKey: Uint8List(32),
      fingerprint: fp,
      pairedAt: DateTime.now().millisecondsSinceEpoch,
    ));

    final agent = _peerAgent(
      id: 'local-proxy',
      peerId: peerId,
      remoteAgentId: remoteId,
    );
    const localChannel = 'dm_abc';
    final placement = await resolvePeerAttachmentPlacement(
      agent: agent,
      localChannelId: localChannel,
      peerStorage: storage,
    );
    expect(placement, isNotNull);
    expect(placement!.deviceId, fp);
    expect(placement.ownerId, remoteId);
    expect(
      placement.channelId,
      peerAgentChannelId(peerId, remoteId, localChannel),
    );
  });

  test('非 peer agent → null', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final agent = RemoteAgent(
      id: 'local-a',
      name: 'Local',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.websocket,
      status: AgentStatus.online,
      capabilities: const [],
      metadata: const {'is_local': true},
      createdAt: now,
      updatedAt: now,
    );
    final placement = await resolvePeerAttachmentPlacement(
      agent: agent,
      localChannelId: 'ch1',
    );
    expect(placement, isNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';

RemoteAgent _agent({
  required String id,
  ProtocolType protocol = ProtocolType.acp,
  Map<String, dynamic>? metadata,
}) {
  final now = 1;
  return RemoteAgent(
    id: id,
    name: 'Agent',
    avatar: '🤖',
    token: 't',
    endpoint: '',
    protocol: protocol,
    connectionType: ConnectionType.http,
    status: AgentStatus.online,
    metadata: metadata ?? const {},
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  const peerId = 'peer-android-aa38';
  const uuid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

  group('matchGroupPeerAgent', () {
    test('matches by remote_agent_id + source_peer_id', () {
      final peer = _agent(
        id: uuid,
        protocol: ProtocolType.peer,
        metadata: {
          'source_peer_id': peerId,
          'remote_agent_id': uuid,
        },
      );
      final other = _agent(
        id: 'local-admin',
        protocol: ProtocolType.acp,
      );
      expect(
        matchGroupPeerAgent(
          groupAgents: [other, peer],
          peerId: peerId,
          remoteAgentId: uuid,
        ),
        peer,
      );
    });

    test('matches the hub id itself', () {
      final peer = _agent(
        id: uuid,
        protocol: ProtocolType.peer,
        metadata: {
          'source_peer_id': peerId,
        },
      );
      expect(
        matchGroupPeerAgent(
          groupAgents: [peer],
          peerId: peerId,
          remoteAgentId: uuid,
        ),
        peer,
      );
    });

    test('returns null when peer is not a group member', () {
      expect(
        matchGroupPeerAgent(
          groupAgents: [
            _agent(id: 'admin', protocol: ProtocolType.acp),
          ],
          peerId: peerId,
          remoteAgentId: uuid,
        ),
        isNull,
      );
    });
  });

  test('row id is the hub id', () {
    expect(peerAgentLocalId(peerId, uuid), uuid);
  });
}

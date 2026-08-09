import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/services/she_service.dart';

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

    test('matches legacy namespaced local id', () {
      final legacyId = legacyPeerAgentLocalId(peerId, uuid);
      final peer = _agent(
        id: legacyId,
        protocol: ProtocolType.peer,
        metadata: {
          'source_peer_id': peerId,
          'remote_agent_id': uuid,
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

  group('decidePeerAgentRowId', () {
    test('reuses hub UUID when no local row exists', () {
      expect(
        decidePeerAgentRowId(peerId: peerId, remoteAgentId: uuid),
        uuid,
      );
    });

    test('prefers existing legacy peeragent_* row', () {
      final legacyId = legacyPeerAgentLocalId(peerId, uuid);
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: uuid,
          existingByLegacyId: _agent(
            id: legacyId,
            protocol: ProtocolType.peer,
            metadata: {
              'source_peer_id': peerId,
              'remote_agent_id': uuid,
            },
          ),
          existingByRemoteId: _agent(id: uuid),
        ),
        legacyId,
      );
    });

    test('reuses hub UUID row already owned by this peer agent', () {
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: uuid,
          existingByRemoteId: _agent(
            id: uuid,
            protocol: ProtocolType.peer,
            metadata: {
              'source_peer_id': peerId,
              'remote_agent_id': uuid,
            },
          ),
        ),
        uuid,
      );
    });

    test('does not overwrite local She when remote id is she-builtin-agent-001',
        () {
      final legacyId =
          legacyPeerAgentLocalId(peerId, SheService.sheId);
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: SheService.sheId,
          existingByRemoteId: _agent(
            id: SheService.sheId,
            protocol: ProtocolType.acp,
            metadata: const {'is_she': true},
          ),
        ),
        legacyId,
      );
    });

    test('does not reuse She id even if it was already stamped as peer', () {
      final legacyId =
          legacyPeerAgentLocalId(peerId, SheService.sheId);
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: SheService.sheId,
          existingByRemoteId: _agent(
            id: SheService.sheId,
            protocol: ProtocolType.peer,
            metadata: {
              'source_peer_id': peerId,
              'source_peer_name': 'Android-AA38',
              'remote_agent_id': SheService.sheId,
            },
          ),
        ),
        legacyId,
      );
    });

    test('namespaces She remote id when She row is absent', () {
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: SheService.sheId,
        ),
        legacyPeerAgentLocalId(peerId, SheService.sheId),
      );
    });

    test('namespaces when hub UUID collides with unrelated local agent', () {
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: uuid,
          existingByRemoteId: _agent(
            id: uuid,
            protocol: ProtocolType.acp,
            metadata: const {'llm_provider': 'openai'},
          ),
        ),
        legacyPeerAgentLocalId(peerId, uuid),
      );
    });

    test('namespaces when hub UUID is owned by a different peer', () {
      expect(
        decidePeerAgentRowId(
          peerId: peerId,
          remoteAgentId: uuid,
          existingByRemoteId: _agent(
            id: uuid,
            protocol: ProtocolType.peer,
            metadata: {
              'source_peer_id': 'other-peer',
              'remote_agent_id': uuid,
            },
          ),
        ),
        legacyPeerAgentLocalId(peerId, uuid),
      );
    });
  });

  group('isReservedLocalAgentId', () {
    test('marks She fixed id as reserved', () {
      expect(isReservedLocalAgentId(SheService.sheId), isTrue);
      expect(isReservedLocalAgentId(uuid), isFalse);
    });
  });
}

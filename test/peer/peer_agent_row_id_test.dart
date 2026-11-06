import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_ids.dart';

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

  group('isPeerAgentRowId', () {
    test('accepts the hub id itself', () {
      expect(isPeerAgentRowId(uuid, peerId, uuid), isTrue);
    });

    test('accepts the legacy namespaced row id', () {
      // commit 392148e1 之前落库的行仍是 peeragent_<peer>_<remote>，没有迁移。
      expect(
        isPeerAgentRowId('peeragent_${peerId}_$uuid', peerId, uuid),
        isTrue,
      );
    });

    test('rejects another peer or another remote agent', () {
      expect(isPeerAgentRowId('peeragent_other_$uuid', peerId, uuid), isFalse);
      expect(
          isPeerAgentRowId('peeragent_${peerId}_other', peerId, uuid), isFalse);
      expect(isPeerAgentRowId('local-admin', peerId, uuid), isFalse);
    });

    test('rejects null', () {
      expect(isPeerAgentRowId(null, peerId, uuid), isFalse);
    });
  });

  group('hubAgentIdFromRaw', () {
    test('strips agent: prefix and legacy peeragent row ids', () {
      expect(hubAgentIdFromRaw(uuid), uuid);
      expect(hubAgentIdFromRaw(' agent:$uuid '), uuid);
      expect(
          hubAgentIdFromRaw('peeragent_${peerId}_$uuid', peerId: peerId), uuid);
      expect(hubAgentIdFromRaw('peeragent_other_$uuid', peerId: peerId),
          'peeragent_other_$uuid');
    });

    test('hubAgentIdOf uses the same normalization for legacy rows', () {
      final legacy = _agent(
        id: 'peeragent_${peerId}_$uuid',
        protocol: ProtocolType.peer,
        metadata: {'source_peer_id': peerId},
      );
      expect(hubAgentIdOf(legacy), uuid);
      final withRemote = _agent(
        id: 'peeragent_${peerId}_$uuid',
        protocol: ProtocolType.peer,
        metadata: {
          'source_peer_id': peerId,
          'remote_agent_id': 'agent:$uuid',
        },
      );
      expect(hubAgentIdOf(withRemote), uuid);
    });
  });

  group('orphanCardBelongsToHostSession', () {
    test('claims only the same session', () {
      expect(
          orphanCardBelongsToHostSession('dm_a_user_1', 'dm_a_user_1'), isTrue);
      expect(
        orphanCardBelongsToHostSession('group-1', 'group-1'),
        isTrue,
      );
      expect(
        orphanCardBelongsToHostSession('dm_other_user_1', 'dm_a_user_1'),
        isFalse,
      );
    });

    test('never claims an unattributed card', () {
      expect(orphanCardBelongsToHostSession(null, 'dm_a_user_1'), isFalse);
      expect(orphanCardBelongsToHostSession('', 'dm_a_user_1'), isFalse);
      expect(orphanCardBelongsToHostSession('   ', 'dm_a_user_1'), isFalse);
      expect(orphanCardBelongsToHostSession('dm_a_user_1', null), isFalse);
      expect(orphanCardBelongsToHostSession('dm_a_user_1', ''), isFalse);
    });
  });
}

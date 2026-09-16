import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/peer/services/peer_agent_client_service.dart';
import 'package:shepaw/services/group/group_member_capability_probe.dart';

RemoteAgent _agent({
  required String id,
  ProtocolType protocol = ProtocolType.acp,
  Map<String, dynamic> metadata = const {},
}) =>
    RemoteAgent(
      id: id,
      name: id,
      token: 't',
      endpoint: 'ws://localhost/acp/ws',
      protocol: protocol,
      connectionType: ConnectionType.websocket,
      metadata: metadata,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  group('GroupMemberCapabilityProbe', () {
    test('local agent is always reachable with store tool', () async {
      final probe = GroupMemberCapabilityProbe(
        checkHealth: (_, {timeout = const Duration(seconds: 3)}) async => false,
      );
      final snap = await probe.probe(
        _agent(id: 'local', metadata: {'llm_provider': 'x'}),
      );
      expect(snap.reachable, isTrue);
      expect(snap.storeCliAvailable, isTrue);
    });

    test('offline remote marks unreachable', () async {
      final probe = GroupMemberCapabilityProbe(
        checkHealth: (_, {timeout = const Duration(seconds: 3)}) async => false,
      );
      final snap = await probe.probe(_agent(id: 'remote'));
      expect(snap.reachable, isFalse);
      expect(snap.storeCliAvailable, isFalse);
    });

    test('peer not running marks store cli unavailable', () async {
      final probe = GroupMemberCapabilityProbe(
        checkHealth: (_, {timeout = const Duration(seconds: 3)}) async => true,
      );
      final snap = await probe.probe(
        _agent(
          id: 'peer',
          protocol: ProtocolType.peer,
          metadata: {'manageable': true, 'running': false},
        ),
      );
      expect(snap.reachable, isTrue);
      expect(snap.storeCliAvailable, isFalse);
    });

    test('peer live hub probe uses agent_manage list + health', () async {
      final probe = GroupMemberCapabilityProbe(
        checkHealth: (_, {timeout = const Duration(seconds: 3)}) async => true,
        peerHubLister: (_) async => const PeerAgentManageResult(
          ok: true,
          hubStoreOk: true,
          agents: [
            PeerAgentManageEntry(
              id: 'inst-1',
              name: 'cursor',
              running: true,
              enabled: true,
              manageable: true,
            ),
          ],
        ),
      );
      final snap = await probe.probe(
        _agent(
          id: 'peer',
          protocol: ProtocolType.peer,
          metadata: {
            'manageable': true,
            'running': false,
            'source_peer_id': 'peer-1',
            'remote_agent_id': 'inst-1',
          },
        ),
      );
      expect(snap.reachable, isTrue);
      expect(snap.storeCliAvailable, isTrue);
      expect(snap.notes.join(' '), contains('/api/v1/health'));
    });
  });
}

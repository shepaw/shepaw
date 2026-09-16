import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
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
  });
}

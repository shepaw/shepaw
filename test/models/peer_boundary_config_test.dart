import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/peer_boundary_config.dart';
import 'package:shepaw/models/prompt_stack_config.dart';
import 'package:shepaw/models/remote_agent.dart';

RemoteAgent _agent({
  required Map<String, dynamic> metadata,
  String id = 'a1',
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: 'Test',
    token: '',
    endpoint: '',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.websocket,
    status: AgentStatus.online,
    capabilities: const [],
    metadata: metadata,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('PeerBoundaryConfig', () {
    test('defaults block os and memory writes', () {
      const c = PeerBoundaryConfig.defaults;
      expect(c.injectExternalPreamble, isTrue);
      expect(c.stripHostUserContext, isTrue);
      expect(c.disableOsTools, isTrue);
      expect(c.disableMemoryWrites, isTrue);
      expect(
        c.blocksCli(namespace: 'os', subcommand: 'command.exec'),
        isTrue,
      );
      expect(
        c.blocksCli(namespace: 'context', subcommand: 'memory.write'),
        isTrue,
      );
      expect(
        c.blocksCli(namespace: 'tools', subcommand: 'web.search'),
        isFalse,
      );
    });

    test('open allows os and memory writes', () {
      const c = PeerBoundaryConfig.open;
      expect(
        c.blocksCli(namespace: 'os', subcommand: 'file.read'),
        isFalse,
      );
      expect(
        c.blocksCli(namespace: 'context', subcommand: 'memory.write'),
        isFalse,
      );
    });

    test('fromJson round-trip', () {
      final c = PeerBoundaryConfig.fromJson({
        'disable_os_tools': false,
        'inject_external_preamble': true,
      });
      expect(c.disableOsTools, isFalse);
      expect(c.injectExternalPreamble, isTrue);
      expect(c.stripHostUserContext, isTrue); // default
      final again = PeerBoundaryConfig.fromJson(c.toJson());
      expect(again.disableOsTools, isFalse);
    });
  });

  group('PeerBoundaryPrompt', () {
    test('preamble mentions external serving', () {
      final text = PeerBoundaryPrompt.buildPreamble(peerDisplayName: 'Phone');
      expect(text, contains('External serving mode'));
      expect(text, contains('Phone'));
      expect(text, contains('Do not reveal'));
    });
  });

  group('RemoteAgent.promptStackConfigForPeerInbound', () {
    test('strips host user context by default', () {
      final agent = _agent(metadata: {
        'is_she': true,
        'llm_provider': 'openai',
      });
      expect(agent.promptStackConfig.she.includeProfileSnapshot, isTrue);
      final inbound = agent.promptStackConfigForPeerInbound();
      expect(inbound.she.includeProfileSnapshot, isFalse);
      expect(inbound.she.includeUserCognition, isFalse);
      expect(inbound.she.includeSessionEnd, isFalse);
      // Soul / identity stack can remain.
      expect(inbound.she.includeSheMemory, isTrue);
    });

    test('respects metadata peer_boundary open', () {
      final agent = _agent(metadata: {
        'is_she': true,
        'llm_provider': 'openai',
        'peer_boundary': PeerBoundaryConfig.open.toJson(),
      });
      final inbound = agent.promptStackConfigForPeerInbound();
      expect(inbound.she.includeProfileSnapshot, isTrue);
      expect(inbound.she.includeSessionEnd, isTrue);
    });
  });
}

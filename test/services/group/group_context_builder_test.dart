import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/acp_protocol.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_context_builder.dart';

RemoteAgent _agent({
  required String id,
  required String name,
  bool local = false,
  bool peer = false,
}) {
  return RemoteAgent(
    id: id,
    name: name,
    token: '',
    endpoint: peer ? '' : 'http://example.com',
    protocol: peer ? ProtocolType.peer : ProtocolType.acp,
    connectionType: ConnectionType.http,
    createdAt: 0,
    updatedAt: 0,
    metadata: {
      if (local) 'llm_provider': 'openai',
      if (peer) ...{
        'source_peer_id': 'peer1',
        'remote_agent_id': 'remote1',
      },
    },
  );
}

void main() {
  group('GroupContextBuilder', () {
    test('build includes mention_mode and member_mention for allMembers member',
        () {
      final alice = _agent(id: 'a1', name: 'Alice', local: true);
      final bob = _agent(id: 'b1', name: 'Bob');

      final ctx = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'Test Group',
        groupDescription: 'desc',
        allAgents: [alice, bob],
        mentionMode: 'allMembers',
        isAdmin: false,
        currentAgent: alice,
      );

      expect(ctx['mention_mode'], 'allMembers');
      expect(ctx['history_policy'], isA<Map<String, dynamic>>());
      expect(ctx['members'], hasLength(2));
      final contract = ctx['member_mention'] as Map<String, dynamic>;
      expect(contract['enabled'], isTrue);
      expect(contract['transport'], 'tool');
      expect(contract['tool_name'], 'group_mention');
      expect(contract['schema'], isNotNull);
    });

    test('build omits member_mention for adminOnly', () {
      final alice = _agent(id: 'a1', name: 'Alice', local: true);
      final bob = _agent(id: 'b1', name: 'Bob');

      final ctx = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'G',
        groupDescription: '',
        allAgents: [alice, bob],
        mentionMode: 'adminOnly',
        isAdmin: false,
        currentAgent: alice,
      );

      expect(ctx['mention_mode'], 'adminOnly');
      expect(ctx.containsKey('member_mention'), isFalse);
    });

    test('remote ACP member gets ui.messageMetadata contract', () {
      final remote = _agent(id: 'r1', name: 'RemoteBot');

      final ctx = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'G',
        groupDescription: '',
        allAgents: [remote],
        mentionMode: 'allMembers',
        isAdmin: false,
        currentAgent: remote,
      );

      final contract = ctx['member_mention'] as Map<String, dynamic>;
      expect(contract['transport'], 'acp_notification');
      expect(contract['acp_method'], ACPMethod.uiMessageMetadata);
    });

    test('peer member gets reply_metadata contract', () {
      final peer = _agent(id: 'p1', name: 'PeerBot', local: true, peer: true);

      final ctx = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'G',
        groupDescription: '',
        allAgents: [peer],
        mentionMode: 'allMembers',
        isAdmin: false,
        currentAgent: peer,
      );

      final contract = ctx['member_mention'] as Map<String, dynamic>;
      expect(contract['transport'], 'reply_metadata');
      expect(contract['peer_event'], 'agent_metadata');
    });

    test('mentionDeclarationHint distinguishes local, peer, remote', () {
      expect(
        GroupContextBuilder.mentionDeclarationHint(
          _agent(id: 'l', name: 'Local', local: true),
        ),
        contains('group_mention'),
      );
      expect(
        GroupContextBuilder.mentionDeclarationHint(
          _agent(id: 'p', name: 'Peer', local: true, peer: true),
        ),
        contains('agent_metadata'),
      );
      expect(
        GroupContextBuilder.mentionDeclarationHint(
          _agent(id: 'r', name: 'Remote'),
        ),
        contains(ACPMethod.uiMessageMetadata),
      );
    });

    test('embedPeerContextBlock wraps JSON for peer relay', () {
      final block = GroupContextBuilder.embedPeerContextBlock({
        'mention_mode': 'allMembers',
      });
      expect(block, contains('【GROUP_CONTEXT】'));
      expect(block, contains('"mention_mode": "allMembers"'));
    });

    test('history_policy documents thinking exclusion for admin and member', () {
      final agents = [_agent(id: 'a1', name: 'Alice', local: true)];

      final memberPolicy = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'G',
        groupDescription: '',
        allAgents: agents,
        isAdmin: false,
        currentAgent: agents.first,
      )['history_policy'] as Map<String, dynamic>;

      final adminPolicy = GroupContextBuilder.build(
        channelId: 'ch1',
        groupName: 'G',
        groupDescription: '',
        allAgents: agents,
        isAdmin: true,
        currentAgent: agents.first,
      )['history_policy'] as Map<String, dynamic>;

      for (final policy in [memberPolicy, adminPolicy]) {
        expect(policy['content_source'], 'message.content');
        expect(
          policy['excludes'],
          containsAll(GroupContextBuilder.historyPolicyExcludes),
        );
        expect(policy['note'], contains('progress_content'));
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/services/group/group_orchestration_tools.dart';

RemoteAgent _agent(String id, String name) => RemoteAgent(
      id: id,
      name: name,
      avatar: '🤖',
      token: '',
      endpoint: '',
      protocol: ProtocolType.acp,
      connectionType: ConnectionType.http,
      createdAt: 0,
      updatedAt: 0,
    );

void main() {
  final agents = [
    _agent('a1', 'Coder'),
    _agent('a2', 'Reviewer'),
  ];

  group('GroupOrchestrationTools.parseDispatchArgs', () {
    test('parses concurrent steps and resolves agent names', () {
      final parsed = GroupOrchestrationTools.parseDispatchArgs(
        {
          'mode': 'concurrent',
          'steps': [
            {
              'step': 1,
              'agents': ['Coder', 'Reviewer'],
              'task': '实现功能',
            },
          ],
        },
        agents,
      );

      expect(parsed.parseError, isNull);
      expect(parsed.steps.length, 1);
      expect(parsed.steps.first.agentIds, ['a1', 'a2']);
      expect(parsed.steps.first.task, '实现功能');
      expect(parsed.steps.first.mode, 'concurrent');
      expect(parsed.unresolvedNames, isEmpty);
    });

    test('matches agent names case-insensitively', () {
      final parsed = GroupOrchestrationTools.parseDispatchArgs(
        {
          'mode': 'sequential',
          'steps': [
            {
              'agents': ['coder'],
              'task': 'fix bug',
            },
          ],
        },
        agents,
      );

      expect(parsed.parseError, isNull);
      expect(parsed.steps.single.agentIds, ['a1']);
      expect(parsed.steps.single.mode, 'sequential');
    });

    test('reports unresolved names when no member matches', () {
      final parsed = GroupOrchestrationTools.parseDispatchArgs(
        {
          'mode': 'concurrent',
          'steps': [
            {
              'agents': ['UnknownBot'],
              'task': 'do stuff',
            },
          ],
        },
        agents,
      );

      expect(parsed.steps, isEmpty);
      expect(parsed.unresolvedNames, ['UnknownBot']);
      expect(parsed.parseError, contains('no group members matched'));
    });

    test('rejects empty steps', () {
      final parsed = GroupOrchestrationTools.parseDispatchArgs(
        {'mode': 'concurrent', 'steps': []},
        agents,
      );

      expect(parsed.steps, isEmpty);
      expect(parsed.parseError, contains('non-empty'));
    });
  });

  group('GroupOrchestrationTools.parseFinishAction', () {
    test('accepts done/continue/pause', () {
      expect(
        GroupOrchestrationTools.parseFinishAction({'action': 'done'}),
        'done',
      );
      expect(
        GroupOrchestrationTools.parseFinishAction({'action': 'CONTINUE'}),
        'continue',
      );
      expect(
        GroupOrchestrationTools.parseFinishAction({'action': 'pause'}),
        'pause',
      );
    });

    test('rejects invalid action', () {
      expect(
        GroupOrchestrationTools.parseFinishAction({'action': 'stop'}),
        isNull,
      );
      expect(GroupOrchestrationTools.parseFinishAction({}), isNull);
    });
  });

  group('tool schemas', () {
    test('openAI tools include enum of agent names', () {
      final tools = GroupOrchestrationTools.openAITools(
        agentNames: ['Coder', 'Reviewer'],
      );
      expect(tools.length, 2);
      final dispatch = tools.first['function'] as Map;
      expect(dispatch['name'], GroupOrchestrationTools.dispatchName);
      final schema = dispatch['parameters'] as Map;
      final agentEnum = (((schema['properties'] as Map)['steps'] as Map)['items']
          as Map)['properties'] as Map;
      final agentsSchema = agentEnum['agents'] as Map;
      expect((agentsSchema['items'] as Map)['enum'], ['Coder', 'Reviewer']);
    });
  });
}

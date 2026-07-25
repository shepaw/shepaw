import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/remote_agent.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/services/workflow/workflow_step_agent_resolver.dart';

RemoteAgent _agent(String id, String name, {Map<String, dynamic>? metadata}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: name,
    token: 't',
    endpoint: 'http://localhost',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.http,
    createdAt: now,
    updatedAt: now,
    metadata: metadata ?? const {},
  );
}

WorkflowStepExecution _step(String id, String agentName, {int stepIndex = 0}) {
  return WorkflowStepExecution(
    id: id,
    workflowExecutionId: 'wf-1',
    stageIndex: 0,
    stepIndex: stepIndex,
    agentName: agentName,
    instruction: 'do $id',
  );
}

void main() {
  group('WorkflowStepAgentResolver.resolve', () {
    final she = _agent(SheService.sheId, SheService.sheName, metadata: {
      'is_she': true,
    });
    final coder = _agent('a-coder', 'CodeBuddy');
    final writer = _agent('a-writer', 'Writer');

    test('prefers channel agents over allAgents', () {
      final channelCopy = _agent('channel-coder', 'CodeBuddy');
      final resolved = WorkflowStepAgentResolver.resolve(
        agentName: 'CodeBuddy',
        channelAgents: [she, channelCopy],
        allAgents: [she, coder, writer],
      );
      expect(resolved?.id, 'channel-coder');
    });

    test('falls back to allAgents by exact name', () {
      final resolved = WorkflowStepAgentResolver.resolve(
        agentName: 'Writer',
        channelAgents: [she],
        allAgents: [she, coder, writer],
      );
      expect(resolved?.id, 'a-writer');
    });

    test('returns null for unknown or empty name', () {
      expect(
        WorkflowStepAgentResolver.resolve(
          agentName: 'Nobody',
          channelAgents: [she],
          allAgents: [coder],
        ),
        isNull,
      );
      expect(
        WorkflowStepAgentResolver.resolve(
          agentName: '',
          channelAgents: [she],
          allAgents: [coder],
        ),
        isNull,
      );
    });
  });

  group('WorkflowStepAgentResolver.runsOnSheChannel', () {
    test('true for She id / is_she metadata', () {
      expect(
        WorkflowStepAgentResolver.runsOnSheChannel(
          _agent(SheService.sheId, 'She'),
        ),
        isTrue,
      );
      expect(
        WorkflowStepAgentResolver.runsOnSheChannel(
          _agent('other', 'She', metadata: {'is_she': true}),
        ),
        isTrue,
      );
    });

    test('false for ordinary agents', () {
      expect(
        WorkflowStepAgentResolver.runsOnSheChannel(_agent('a1', 'CodeBuddy')),
        isFalse,
      );
    });
  });

  group('WorkflowStepAgentResolver.groupStepExecutions', () {
    test('groups by agent preserving order; same agent stays together', () {
      final steps = [
        _step('1', 'CodeBuddy', stepIndex: 0),
        _step('2', 'She', stepIndex: 1),
        _step('3', 'CodeBuddy', stepIndex: 2),
        _step('4', 'Writer', stepIndex: 3),
      ];
      final groups = WorkflowStepAgentResolver.groupStepExecutions(steps);
      expect(groups.length, 3);
      expect(groups[0].map((s) => s.id).toList(), ['1', '3']);
      expect(groups[1].map((s) => s.id).toList(), ['2']);
      expect(groups[2].map((s) => s.id).toList(), ['4']);
    });

    test('empty input yields empty groups', () {
      expect(WorkflowStepAgentResolver.groupStepExecutions(const []), isEmpty);
    });
  });
}

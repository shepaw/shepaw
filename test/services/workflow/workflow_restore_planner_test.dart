import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/models/workflow_pending_approval.dart';
import 'package:shepaw/services/workflow/workflow_pending_approval_picker.dart';
import 'package:shepaw/services/workflow/workflow_restore_planner.dart';

WorkflowExecution _wf({
  WorkflowStatus status = WorkflowStatus.running,
  List<WorkflowStepExecution> steps = const [],
}) {
  return WorkflowExecution(
    id: 'wf-1',
    channelId: 'ch-1',
    title: 'Test',
    flowPlanJson: '{}',
    status: status,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    steps: steps,
  );
}

WorkflowStepExecution _step(
  String id,
  StepExecutionStatus status, {
  String? outputSummary,
}) {
  return WorkflowStepExecution(
    id: id,
    workflowExecutionId: 'wf-1',
    stageIndex: 0,
    stepIndex: 0,
    agentName: 'A',
    instruction: 'do',
    status: status,
    outputSummary: outputSummary,
  );
}

void main() {
  group('WorkflowRestorePlanner', () {
    test('none when active missing or not running', () {
      expect(
        WorkflowRestorePlanner.plan(
          active: null,
          isExecutingInProcess: false,
          hasLocalCancelToken: false,
        ).kind,
        WorkflowRestoreActionKind.none,
      );
      expect(
        WorkflowRestorePlanner.plan(
          active: _wf(status: WorkflowStatus.completed),
          isExecutingInProcess: false,
          hasLocalCancelToken: false,
        ).kind,
        WorkflowRestoreActionKind.none,
      );
    });

    test('reattachOnly when ChatService already executing', () {
      expect(
        WorkflowRestorePlanner.plan(
          active: _wf(),
          isExecutingInProcess: true,
          hasLocalCancelToken: false,
        ).kind,
        WorkflowRestoreActionKind.reattachOnly,
      );
    });

    test('finalizeSucceeded / finalizeFailed', () {
      expect(
        WorkflowRestorePlanner.plan(
          active: _wf(),
          isExecutingInProcess: false,
          hasLocalCancelToken: false,
          withSteps: _wf(steps: [
            _step('1', StepExecutionStatus.completed),
            _step('2', StepExecutionStatus.skipped),
          ]),
        ).kind,
        WorkflowRestoreActionKind.finalizeSucceeded,
      );
      expect(
        WorkflowRestorePlanner.plan(
          active: _wf(),
          isExecutingInProcess: false,
          hasLocalCancelToken: false,
          withSteps: _wf(steps: [
            _step('1', StepExecutionStatus.completed),
            _step('2', StepExecutionStatus.failed),
          ]),
        ).kind,
        WorkflowRestoreActionKind.finalizeFailed,
      );
    });

    test('heal orphans then finalize or resume', () {
      final finalize = WorkflowRestorePlanner.plan(
        active: _wf(),
        isExecutingInProcess: false,
        hasLocalCancelToken: false,
        withSteps: _wf(steps: [
          _step('1', StepExecutionStatus.running),
          _step('2', StepExecutionStatus.completed),
        ]),
      );
      expect(finalize.kind, WorkflowRestoreActionKind.healOrphansThenFinalize);
      expect(finalize.stuckRunning, hasLength(1));

      final resume = WorkflowRestorePlanner.plan(
        active: _wf(),
        isExecutingInProcess: false,
        hasLocalCancelToken: false,
        withSteps: _wf(steps: [
          _step('1', StepExecutionStatus.running),
          _step('2', StepExecutionStatus.pending),
        ]),
      );
      expect(resume.kind, WorkflowRestoreActionKind.healOrphansThenResume);
      expect(resume.shouldResume, isTrue);
    });

    test('resumePending when interrupted with pending work', () {
      final plan = WorkflowRestorePlanner.plan(
        active: _wf(),
        isExecutingInProcess: false,
        hasLocalCancelToken: false,
        withSteps: _wf(steps: [
          _step('1', StepExecutionStatus.completed),
          _step('2', StepExecutionStatus.pending),
        ]),
      );
      expect(plan.kind, WorkflowRestoreActionKind.resumePending);
      expect(plan.pendingCount, 1);
    });

    test('none when local cancel token already owns the loop', () {
      expect(
        WorkflowRestorePlanner.plan(
          active: _wf(),
          isExecutingInProcess: false,
          hasLocalCancelToken: true,
          withSteps: _wf(steps: [
            _step('1', StepExecutionStatus.pending),
          ]),
        ).kind,
        WorkflowRestoreActionKind.none,
      );
    });
  });

  group('WorkflowPendingApprovalPicker', () {
    test('pickDbRecord prefers matching workflow id', () {
      final a = WorkflowPendingApproval(
        id: '1',
        workflowId: 'wf-a',
        stepId: 's1',
        channelId: 'ch',
        agentId: 'a',
        agentName: 'A',
        peerId: 'p',
        remoteAgentId: 'r',
        confirmationId: 'c1',
        peerSessionId: 'sess',
        approvalData: const {},
        createdAt: 1,
      );
      final b = WorkflowPendingApproval(
        id: '2',
        workflowId: 'wf-b',
        stepId: 's2',
        channelId: 'ch',
        agentId: 'a',
        agentName: 'A',
        peerId: 'p',
        remoteAgentId: 'r',
        confirmationId: 'c2',
        peerSessionId: 'sess',
        approvalData: const {},
        createdAt: 2,
      );
      expect(
        WorkflowPendingApprovalPicker.pickDbRecord(
          dbPending: [a, b],
          activeWorkflowId: 'wf-b',
        )?.id,
        '2',
      );
      expect(
        WorkflowPendingApprovalPicker.pickDbRecord(
          dbPending: [a, b],
          activeWorkflowId: null,
        )?.id,
        '1',
      );
    });

    test('findInMessages recovers unanswered peer approval card', () {
      final msg = Message(
        id: 'm1',
        content: 'need approval',
        timestampMs: 1,
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Coder'),
        type: MessageType.text,
        metadata: {
          'action_confirmation': {
            '_workflowPeerApproval': true,
            '_workflowId': 'wf-1',
            '_workflowStepId': 'step-1',
            '_approvalRisk': 'low',
            'confirmation_id': 'conf-9',
            'prompt': 'Read file',
          },
        },
      );
      final pending = WorkflowPendingApprovalPicker.findInMessages(
        activeWorkflowId: 'wf-1',
        messages: [msg],
      );
      expect(pending?.confirmationId, 'conf-9');
      expect(pending?.stepId, 'step-1');
      expect(pending?.risk, PeerApprovalRisk.low);
      expect(pending?.messageId, 'm1');
    });

    test('findInMessages skips already selected cards', () {
      final msg = Message(
        id: 'm1',
        content: 'done',
        timestampMs: 1,
        from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Coder'),
        type: MessageType.text,
        metadata: {
          'action_confirmation': {
            '_workflowPeerApproval': true,
            '_workflowId': 'wf-1',
            '_workflowStepId': 'step-1',
            'selected_action_id': 'allow',
            'confirmation_id': 'conf-9',
          },
        },
      );
      expect(
        WorkflowPendingApprovalPicker.findInMessages(
          activeWorkflowId: 'wf-1',
          messages: [msg],
        ),
        isNull,
      );
    });
  });
}

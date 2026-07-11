import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_workflow_panel_state.dart';
import 'package:shepaw/models/workflow_models.dart';
import 'package:shepaw/peer/peer_approval_selection.dart';

WorkflowPeerApprovalPending _pending({
  required String stepId,
  required String? confirmationId,
}) {
  return WorkflowPeerApprovalPending(
    workflowId: 'wf-1',
    stepId: stepId,
    agentId: 'a1',
    agentName: 'Agent',
    confirmationId: confirmationId,
  );
}

void main() {
  group('PeerApprovalSelection.applySelection', () {
    test('merges selected action fields', () {
      final data = <String, dynamic>{'prompt': 'Run'};
      PeerApprovalSelection.applySelection(
        data,
        {
          'selected_action_id': 'allow',
          'selected_action_label': '允许',
        },
        selectedAtMs: 123,
      );
      expect(data['selected_action_id'], 'allow');
      expect(data['selected_action_label'], '允许');
      expect(data['selected_at'], 123);
      expect(data['prompt'], 'Run');
    });

    test('ignores empty selected_action_id', () {
      final data = <String, dynamic>{};
      PeerApprovalSelection.applySelection(data, {'selected_action_id': ''});
      expect(data.containsKey('selected_action_id'), isFalse);
    });
  });

  group('PeerApprovalSelection.shouldSupersede', () {
    test('true when same step and different confirmation ids', () {
      expect(
        PeerApprovalSelection.shouldSupersede(
          prev: _pending(stepId: 's1', confirmationId: 'c1'),
          newStepId: 's1',
          newConfirmationId: 'c2',
        ),
        isTrue,
      );
    });

    test('false when step differs', () {
      expect(
        PeerApprovalSelection.shouldSupersede(
          prev: _pending(stepId: 's1', confirmationId: 'c1'),
          newStepId: 's2',
          newConfirmationId: 'c2',
        ),
        isFalse,
      );
    });

    test('false when confirmation id unchanged', () {
      expect(
        PeerApprovalSelection.shouldSupersede(
          prev: _pending(stepId: 's1', confirmationId: 'c1'),
          newStepId: 's1',
          newConfirmationId: 'c1',
        ),
        isFalse,
      );
    });

    test('false when prev missing', () {
      expect(
        PeerApprovalSelection.shouldSupersede(
          prev: null,
          newStepId: 's1',
          newConfirmationId: 'c1',
        ),
        isFalse,
      );
    });
  });

  group('PeerApprovalSelection.buildSupersededDenyResponse', () {
    test('marks supersede and deny', () {
      final deny = PeerApprovalSelection.buildSupersededDenyResponse();
      expect(deny['selected_action_id'], 'deny');
      expect(deny['_superseded'], isTrue);
      expect(deny['_approval_submitted'], isFalse);
    });
  });

  group('PeerApprovalSelection.shouldClearPendingAfterCompletion', () {
    test('clears when confirmation id still matches', () {
      expect(
        PeerApprovalSelection.shouldClearPendingAfterCompletion(
          pending: _pending(stepId: 's1', confirmationId: 'c1'),
          completedConfirmationId: 'c1',
          completedStepId: 's1',
        ),
        isTrue,
      );
    });

    test('does not clear when a newer confirmation replaced it', () {
      expect(
        PeerApprovalSelection.shouldClearPendingAfterCompletion(
          pending: _pending(stepId: 's1', confirmationId: 'c2'),
          completedConfirmationId: 'c1',
          completedStepId: 's1',
        ),
        isFalse,
      );
    });

    test('falls back to step id when completed confirmation is empty', () {
      expect(
        PeerApprovalSelection.shouldClearPendingAfterCompletion(
          pending: _pending(stepId: 's1', confirmationId: 'c1'),
          completedConfirmationId: null,
          completedStepId: 's1',
        ),
        isTrue,
      );
    });
  });

  group('ChatWorkflowPanelState', () {
    test('show/dismiss/reopen and clear peer approval', () {
      final panel = ChatWorkflowPanelState();
      expect(panel.showProgressPanel, isFalse);

      panel.setActiveWorkflowId('wf-1');
      expect(panel.showProgressPanel, isTrue);
      expect(panel.needsPanelAttention, isFalse);

      panel.dismiss();
      expect(panel.showProgressPanel, isFalse);
      expect(panel.needsPanelAttention, isTrue);

      panel.reopen();
      expect(panel.showProgressPanel, isTrue);

      panel.setPeerApprovalPending(_pending(stepId: 's1', confirmationId: 'c1'));
      expect(panel.peerApprovalPending?.confirmationId, 'c1');
      expect(panel.dismissed, isFalse);

      panel.setActiveWorkflowId(null);
      expect(panel.peerApprovalPending, isNull);
      expect(panel.activeWorkflowId, isNull);
    });
  });
}

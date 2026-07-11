import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_workflow_coordinator.dart';
import 'package:shepaw/models/workflow_models.dart';

void main() {
  group('ChatWorkflowCoordinator', () {
    test('panel and streaming bookkeeping', () {
      final c = ChatWorkflowCoordinator();
      c.setActiveWorkflowId('wf-1');
      expect(c.showProgressPanel, isTrue);

      c.trackAgentStart('a1', 'sid-1');
      expect(c.appendStreamChunk('a1', 'hi'), 'hi');
      expect(c.appendStreamChunk('a1', '!'), 'hi!');
      expect(c.removeAgentStreaming('a1'), 'sid-1');
      expect(c.streamingIdFor('a1'), isNull);

      c.setPeerApprovalPending(const WorkflowPeerApprovalPending(
        workflowId: 'wf-1',
        stepId: 's1',
        agentId: 'a1',
        agentName: 'A',
        confirmationId: 'c1',
      ));
      c.onExecutionFinished();
      expect(c.peerApprovalPending, isNull);
      expect(c.hasLocalExecution, isFalse);
      expect(c.activeWorkflowId, 'wf-1');

      c.prepareLocalCancel();
      expect(c.activeWorkflowId, isNull);
    });

    test('interactionPendingKey prefers confirmation_id', () {
      expect(
        ChatWorkflowCoordinator.interactionPendingKey(
          interactionType: 'action_confirmation',
          data: {'confirmation_id': 'conf-1'},
          sid: 'sid',
          agentId: 'a1',
        ),
        'conf-1',
      );
      expect(
        ChatWorkflowCoordinator.interactionPendingKey(
          interactionType: 'form',
          data: {},
          sid: 'sid',
          agentId: 'a1',
        ),
        'sid',
      );
    });

    test('registerWorkflowPeerApproval supersedes same-step pending', () {
      final c = ChatWorkflowCoordinator();
      c.setActiveWorkflowId('wf-1');
      expect(
        c.registerWorkflowPeerApproval(
          agentId: 'a1',
          agentName: 'Coder',
          messageId: 'm1',
          data: {
            '_workflowPeerApproval': true,
            '_workflowStepId': 's1',
            'confirmation_id': 'c1',
            'prompt': 'first',
          },
        ),
        isNull,
      );
      expect(c.peerApprovalPending?.confirmationId, 'c1');

      expect(
        c.registerWorkflowPeerApproval(
          agentId: 'a1',
          agentName: 'Coder',
          messageId: 'm2',
          data: {
            '_workflowPeerApproval': true,
            '_workflowStepId': 's1',
            'confirmation_id': 'c2',
            'prompt': 'second',
          },
        ),
        'c1',
      );
      expect(c.peerApprovalPending?.confirmationId, 'c2');

      expect(
        c.clearPeerApprovalIfCurrent(
          completedConfirmationId: 'c1',
          completedStepId: 's1',
        ),
        isFalse,
      );
      expect(c.peerApprovalPending?.confirmationId, 'c2');
      expect(
        c.clearPeerApprovalIfCurrent(
          completedConfirmationId: 'c2',
          completedStepId: 's1',
        ),
        isTrue,
      );
      expect(c.peerApprovalPending, isNull);
    });
  });
}

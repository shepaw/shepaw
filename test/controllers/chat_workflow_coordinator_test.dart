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
  });
}

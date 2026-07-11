import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/workflow_pending_approval.dart';
import 'package:shepaw/models/workflow_models.dart';

void main() {
  WorkflowPendingApproval build({
    Map<String, dynamic> approvalData = const {},
    String status = 'pending',
  }) {
    return WorkflowPendingApproval(
      id: 'wpa-1',
      workflowId: 'wf-1',
      stepId: 'step-1',
      channelId: 'ch-1',
      agentId: 'agent-1',
      agentName: 'Coder',
      peerId: 'peer-1',
      remoteAgentId: 'remote-1',
      confirmationId: 'conf-1',
      peerSessionId: 'sess-1',
      messageId: 'msg-1',
      approvalData: approvalData,
      status: status,
      createdAt: 1000,
      expiresAt: 2000,
    );
  }

  group('WorkflowPendingApproval', () {
    test('risk defaults to high when missing', () {
      expect(build().risk, PeerApprovalRisk.high);
    });

    test('risk parses low from approval data', () {
      expect(
        build(approvalData: {'_approvalRisk': 'low'}).risk,
        PeerApprovalRisk.low,
      );
    });

    test('toUiPending copies fields', () {
      final pending = build(approvalData: {
        '_approvalRisk': 'low',
        'prompt': 'Read file',
      });
      final ui = pending.toUiPending();
      expect(ui.workflowId, 'wf-1');
      expect(ui.stepId, 'step-1');
      expect(ui.agentName, 'Coder');
      expect(ui.confirmationId, 'conf-1');
      expect(ui.prompt, 'Read file');
      expect(ui.risk, PeerApprovalRisk.low);
      expect(ui.messageId, 'msg-1');
    });

    test('toMap/fromMap roundtrip', () {
      final original = build(approvalData: {
        '_approvalRisk': 'high',
        'prompt': 'rm -rf',
      });
      final restored = WorkflowPendingApproval.fromMap(original.toMap());
      expect(restored.id, original.id);
      expect(restored.workflowId, original.workflowId);
      expect(restored.confirmationId, original.confirmationId);
      expect(restored.approvalData['prompt'], 'rm -rf');
      expect(restored.risk, PeerApprovalRisk.high);
      expect(restored.isPending, isTrue);
    });

    test('isPending respects status', () {
      expect(build(status: 'resolved').isPending, isFalse);
    });
  });
}

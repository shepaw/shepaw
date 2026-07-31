import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/approval/pending_approval_item.dart';
import 'package:shepaw/services/approval/pending_approval_reconciler.dart';

Message _msg({
  required String id,
  Map<String, dynamic>? metadata,
}) =>
    Message(
      id: id,
      content: 'hi',
      timestampMs: 1,
      from: MessageFrom(id: 'agent', type: 'agent', name: 'Agent'),
      type: MessageType.text,
      metadata: metadata,
    );

void main() {
  test('plan hub item is resolved when message already responded', () {
    const item = PendingApprovalItem(
      id: 'plan:wf-1',
      channelId: 'ch1',
      messageId: 'm1',
      agentId: 'a1',
      agentName: 'Agent',
      kind: PendingApprovalKind.plan,
      createdAt: 1,
    );
    final messages = [
      _msg(
        id: 'm1',
        metadata: {
          'plan_approval': {'_workflowId': 'wf-1', '_approved': true},
          'plan_approval_responded': {'approved': true},
        },
      ),
    ];

    expect(PendingApprovalReconciler.isResolvedInMessages(item, messages), isTrue);
  });

  test('plan hub item matches workflow id even without messageId', () {
    const item = PendingApprovalItem(
      id: 'plan:wf-1',
      channelId: 'ch1',
      agentId: 'a1',
      agentName: 'Agent',
      kind: PendingApprovalKind.plan,
      createdAt: 1,
    );
    final messages = [
      _msg(
        id: 'other',
        metadata: {
          'plan_approval': {'_workflowId': 'wf-1', '_approved': false},
          'plan_approval_responded': {'approved': false},
        },
      ),
    ];

    expect(PendingApprovalReconciler.isResolvedInMessages(item, messages), isTrue);
  });

  test('action hub item is resolved when confirmation already selected', () {
    const item = PendingApprovalItem(
      id: 'action:cid-1',
      channelId: 'ch1',
      messageId: 'm2',
      agentId: 'a1',
      agentName: 'Agent',
      kind: PendingApprovalKind.action,
      createdAt: 1,
    );
    final messages = [
      _msg(
        id: 'm2',
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'cid-1',
            'selected_action_id': 'allow',
          },
        },
      ),
    ];

    expect(PendingApprovalReconciler.isResolvedInMessages(item, messages), isTrue);
  });

  test('unanswered plan message keeps item unresolved', () {
    const item = PendingApprovalItem(
      id: 'plan:wf-1',
      channelId: 'ch1',
      messageId: 'm1',
      agentId: 'a1',
      agentName: 'Agent',
      kind: PendingApprovalKind.plan,
      createdAt: 1,
    );
    final messages = [
      _msg(
        id: 'm1',
        metadata: {
          'plan_approval': {'_workflowId': 'wf-1'},
        },
      ),
    ];

    expect(PendingApprovalReconciler.isResolvedInMessages(item, messages), isFalse);
  });

  test('findResolvedMessage returns matching plan message', () {
    const item = PendingApprovalItem(
      id: 'plan:wf-1',
      channelId: 'ch1',
      agentId: 'a1',
      agentName: 'Agent',
      kind: PendingApprovalKind.plan,
      createdAt: 1,
    );
    final message = _msg(
      id: 'other',
      metadata: {
        'plan_approval': {'_workflowId': 'wf-1', '_approved': true},
        'plan_approval_responded': {'approved': true},
      },
    );

    expect(
      PendingApprovalReconciler.findResolvedMessage(item, [message])?.id,
      'other',
    );
    expect(PendingApprovalReconciler.planApprovalDecision(message), isTrue);
  });

  test('actionSelectedId prefers selected_action_id then responded action_id', () {
    final withSelected = _msg(
      id: 'm1',
      metadata: {
        'action_confirmation': {
          'confirmation_id': 'cid-1',
          'selected_action_id': 'allow',
        },
      },
    );
    final withResponded = _msg(
      id: 'm2',
      metadata: {
        'action_confirmation': {'confirmation_id': 'cid-2'},
        'action_confirmation_responded': {
          'action_id': 'deny',
          'action_label': 'Deny',
        },
      },
    );

    expect(PendingApprovalReconciler.actionSelectedId(withSelected), 'allow');
    expect(PendingApprovalReconciler.actionSelectedId(withResponded), 'deny');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/workflow/workflow_plan_approval_sync.dart';

Message _msg({
  required String id,
  Map<String, dynamic>? plan,
  Map<String, dynamic>? responded,
}) {
  return Message(
    id: id,
    content: 'plan',
    timestampMs: 1,
    from: MessageFrom(id: 'a', type: 'agent', name: 'Admin'),
    type: MessageType.text,
    metadata: {
      if (plan != null) 'plan_approval': plan,
      if (responded != null) 'plan_approval_responded': responded,
    },
  );
}

void main() {
  group('WorkflowPlanApprovalSync', () {
    test('findPlanApprovalMessage prefers matching workflow id', () {
      final messages = [
        _msg(id: 'm1', plan: {'_workflowId': 'wf-old'}),
        _msg(id: 'm2', plan: {'_workflowId': 'wf-1'}),
      ];
      expect(
        WorkflowPlanApprovalSync.findPlanApprovalMessage(
          messages: messages,
          workflowId: 'wf-1',
        )?.id,
        'm2',
      );
    });

    test('findPlanApprovalMessage falls back to latest unanswered', () {
      final messages = [
        _msg(id: 'm1', plan: {'_workflowId': 'other', '_approved': true}),
        _msg(id: 'm2', plan: {'title': 'unanswered'}),
      ];
      expect(
        WorkflowPlanApprovalSync.findPlanApprovalMessage(
          messages: messages,
          workflowId: 'wf-missing',
        )?.id,
        'm2',
      );
    });

    test('preferPersisted skips streaming host when durable row exists', () {
      final messages = [
        _msg(id: 'streaming_1', plan: {'_workflowId': 'wf-1'}),
        _msg(id: 'uuid-1', plan: {'_workflowId': 'wf-1'}),
      ];
      expect(
        WorkflowPlanApprovalSync.findPlanApprovalMessage(
          messages: messages,
          workflowId: 'wf-1',
          preferPersisted: true,
        )?.id,
        'uuid-1',
      );
      expect(
        WorkflowPlanApprovalSync.findPlanApprovalMessage(
          messages: messages,
          workflowId: 'wf-1',
        )?.id,
        'uuid-1',
      );
    });

    test('preferPersisted returns null when only ephemeral host exists', () {
      final messages = [
        _msg(id: 'streaming_1', plan: {'_workflowId': 'wf-1'}),
      ];
      expect(
        WorkflowPlanApprovalSync.findPlanApprovalMessage(
          messages: messages,
          workflowId: 'wf-1',
          preferPersisted: true,
        ),
        isNull,
      );
    });

    test('buildRespondedPatch and completer payload', () {
      expect(
        WorkflowPlanApprovalSync.buildRespondedPatch(
          approved: false,
          feedback: 'replan',
        ),
        {'approved': false, 'feedback': 'replan'},
      );
      expect(
        WorkflowPlanApprovalSync.buildCompleterPayload(
          approved: true,
          skippedTaskIds: ['t1'],
        ),
        {
          'approved': true,
          'skipped_task_ids': ['t1'],
        },
      );
    });

    test('mergeApprovedFlag copies and sets _approved', () {
      final merged = WorkflowPlanApprovalSync.mergeApprovedFlag(
        {'title': 'Plan', '_workflowId': 'wf-1'},
        true,
      );
      expect(merged['_approved'], isTrue);
      expect(merged['title'], 'Plan');
      expect(merged.containsKey('_workflowId'), isTrue);
    });

    test('applyResponseToMetadata sets responded and _approved', () {
      final meta = WorkflowPlanApprovalSync.applyResponseToMetadata(
        {
          'plan_approval': {'title': 'P', '_workflowId': 'wf-1'},
          'trace_id': 't1',
        },
        approved: true,
      );
      expect(meta['plan_approval_responded'], {'approved': true});
      expect(
        (meta['plan_approval'] as Map)['_approved'],
        isTrue,
      );
      expect(meta['trace_id'], 't1');
    });

    test('isEphemeralHostId covers DM and group temps', () {
      expect(WorkflowPlanApprovalSync.isEphemeralHostId('streaming_abc'), isTrue);
      expect(
        WorkflowPlanApprovalSync.isEphemeralHostId('group_streaming_1'),
        isTrue,
      );
      expect(WorkflowPlanApprovalSync.isEphemeralHostId('uuid-real'), isFalse);
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/approval/pending_approval_hub.dart';
import 'package:shepaw/services/approval/pending_approval_item.dart';

void main() {
  late PendingApprovalHub hub;

  setUp(() {
    hub = PendingApprovalHub.instance;
    hub.resetForTest();
  });

  tearDown(() {
    hub.resetForTest();
  });

  test('upsert merges messageId and emits stream', () async {
    final events = <int>[];
    final sub = hub.stream.listen((items) => events.add(items.length));

    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 1,
      ),
    );
    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        messageId: 'msg1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 2,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    // Identical re-upsert must not churn listeners.
    final before = events.length;
    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        messageId: 'msg1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 3,
      ),
    );

    await Future<void>.delayed(Duration.zero);
    expect(hub.all, hasLength(1));
    expect(hub.all.first.messageId, 'msg1');
    expect(hub.countForChannel('ch1'), 1);
    expect(events.length, before);
    await sub.cancel();
  });

  test('resolve removes item', () {
    hub.upsert(
      PendingApprovalItem(
        id: 'action:c1',
        channelId: 'ch1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.action,
        createdAt: 1,
      ),
    );
    hub.resolveByConfirmationId('c1');
    expect(hub.all, isEmpty);
  });

  test('reconcileForChannel drops resolved plan reminder', () async {
    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        messageId: 'm1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 1,
      ),
    );

    await hub.reconcileForChannel(
      'ch1',
      [
        Message(
          id: 'm1',
          content: 'plan',
          timestampMs: 1,
          from: MessageFrom(id: 'a1', type: 'agent', name: 'Agent'),
          type: MessageType.text,
          metadata: {
            'plan_approval': {'_workflowId': 'wf1', '_approved': true},
            'plan_approval_responded': {'approved': true},
          },
        ),
      ],
    );

    expect(hub.all, isEmpty);
  });

  test('dismiss hides reminder until approval resolves', () {
    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 1,
      ),
    );
    expect(hub.all, hasLength(1));

    hub.dismiss('plan:wf1');
    expect(hub.all, isEmpty);

    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 2,
      ),
    );
    expect(hub.all, isEmpty);

    hub.resolveByWorkflowId('wf1');
    hub.upsert(
      PendingApprovalItem(
        id: 'plan:wf1',
        channelId: 'ch1',
        agentId: 'a1',
        agentName: 'Agent',
        kind: PendingApprovalKind.plan,
        createdAt: 3,
      ),
    );
    expect(hub.all, hasLength(1));
  });

  test('fromInteraction builds plan and action ids', () {
    final plan = PendingApprovalItem.fromInteraction(
      channelId: 'ch',
      agentId: 'a',
      agentName: 'N',
      interactionType: 'plan_approval',
      data: {'_workflowId': 'wf'},
      messageId: 'm',
    );
    expect(plan?.id, 'plan:wf');
    expect(plan?.kind, PendingApprovalKind.plan);

    final action = PendingApprovalItem.fromInteraction(
      channelId: 'ch',
      agentId: 'a',
      agentName: 'N',
      interactionType: 'action_confirmation',
      data: {'confirmation_id': 'cid'},
      messageId: 'm',
    );
    expect(action?.id, 'action:cid');

    final ignored = PendingApprovalItem.fromInteraction(
      channelId: 'ch',
      agentId: 'a',
      agentName: 'N',
      interactionType: 'form',
      data: const {},
    );
    expect(ignored, isNull);
  });

  test('latest is newest by createdAt', () {
    hub.upsert(
      PendingApprovalItem(
        id: 'a',
        channelId: 'c',
        agentId: 'x',
        agentName: 'Old',
        kind: PendingApprovalKind.plan,
        createdAt: 1,
      ),
    );
    hub.upsert(
      PendingApprovalItem(
        id: 'b',
        channelId: 'c',
        agentId: 'x',
        agentName: 'New',
        kind: PendingApprovalKind.action,
        createdAt: 9,
      ),
    );
    expect(hub.latest?.agentName, 'New');
  });
}

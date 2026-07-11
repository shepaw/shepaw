import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/group_interaction_planner.dart';
import 'package:shepaw/models/mention_entry.dart';

void main() {
  group('GroupInteractionPlanner', () {
    test('nonBlocking types include plan_approval and forms', () {
      expect(GroupInteractionPlanner.isNonBlocking('plan_approval'), isTrue);
      expect(GroupInteractionPlanner.isNonBlocking('form'), isTrue);
      expect(GroupInteractionPlanner.isNonBlocking('unknown'), isFalse);
      expect(
        GroupInteractionPlanner.nonBlockingResult(),
        {'_non_blocking': true},
      );
    });

    test('workflowIdFromPlanApproval only for plan_approval', () {
      expect(
        GroupInteractionPlanner.workflowIdFromPlanApproval('plan_approval', {
          '_workflowId': 'wf1',
        }),
        'wf1',
      );
      expect(
        GroupInteractionPlanner.workflowIdFromPlanApproval(
          'action_confirmation',
          {'_workflowId': 'wf1'},
        ),
        isNull,
      );
    });

    test('resolvePreferredSid respects preferSaved', () {
      bool has(String id) => id == 'saved';
      expect(
        GroupInteractionPlanner.resolvePreferredSid(
          streamingSid: 'stream',
          savedMessageId: 'saved',
          hasMessage: has,
        ),
        'stream',
      );
      expect(
        GroupInteractionPlanner.resolvePreferredSid(
          streamingSid: 'stream',
          savedMessageId: 'saved',
          hasMessage: has,
          preferSaved: true,
        ),
        'saved',
      );
      expect(
        GroupInteractionPlanner.resolvePreferredSid(
          streamingSid: null,
          savedMessageId: 'missing',
          hasMessage: has,
        ),
        isNull,
      );
    });

    test('takeSavedMessageId mutates payload', () {
      final data = <String, dynamic>{'_savedMessageId': 'm1', 'x': 1};
      expect(GroupInteractionPlanner.takeSavedMessageId(data), 'm1');
      expect(data.containsKey('_savedMessageId'), isFalse);
      expect(data['x'], 1);
    });

    test('pendingKey uses confirmation_id for action_confirmation', () {
      expect(
        GroupInteractionPlanner.pendingKey(
          interactionType: 'action_confirmation',
          data: {'confirmation_id': 'cid'},
          sid: 'sid',
          agentId: 'a',
        ),
        'cid',
      );
      expect(
        GroupInteractionPlanner.pendingKey(
          interactionType: 'form',
          data: {},
          sid: 'sid',
          agentId: 'a',
        ),
        'sid',
      );
    });

    test('metadataForPersist merges interaction section', () {
      final meta = GroupInteractionPlanner.metadataForPersist(
        existing: {'k': 1},
        interactionType: 'form',
        data: {'fields': []},
      );
      expect(meta['k'], 1);
      expect(meta['form'], {'fields': []});
    });

    test('needsPeerApprovalFallback for peer context without host', () {
      expect(
        GroupInteractionPlanner.needsPeerApprovalFallback(
          preferredSid: null,
          preferredExists: false,
          interactionType: 'action_confirmation',
          data: {'confirmation_context': 'peer'},
          hasChannel: true,
        ),
        isTrue,
      );
      expect(
        GroupInteractionPlanner.needsPeerApprovalFallback(
          preferredSid: 's1',
          preferredExists: true,
          interactionType: 'action_confirmation',
          data: {'confirmation_context': 'peer'},
          hasChannel: true,
        ),
        isFalse,
      );
    });

    test('shouldDropSkippedPlaceholder', () {
      expect(
        GroupInteractionPlanner.shouldDropSkippedPlaceholder(
          skipped: true,
          sid: 's',
        ),
        isTrue,
      );
      expect(
        GroupInteractionPlanner.shouldDropSkippedPlaceholder(
          skipped: false,
          sid: 's',
        ),
        isFalse,
      );
    });

    test('optimistic user + streaming helpers', () {
      final user = GroupInteractionPlanner.buildOptimisticUserMessage(
        content: 'hi',
        userId: 'u',
        userName: 'U',
        replyToId: 'r',
        nowMs: 42,
      );
      expect(user.id, 'temp_user_42');
      expect(user.replyTo, 'r');

      final sid = GroupInteractionPlanner.groupStreamingId('a', nowMs: 7);
      expect(sid, 'group_streaming_a_7');
      final sm = GroupInteractionPlanner.buildAgentStreamingPlaceholder(
        sid: sid,
        agentId: 'a',
        agentName: 'A',
        userId: 'u',
        userName: 'U',
        timestampMs: 8,
      );
      expect(sm.id, sid);
      expect(sm.content, isEmpty);

      expect(
        GroupInteractionPlanner.userMessageMentionsMetadata(const []),
        isNull,
      );
      expect(
        GroupInteractionPlanner.userMessageMentionsMetadata(const [
          MentionEntry(id: 'a', name: 'A', notify: true),
        ])?['mentions'],
        isA<List>(),
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_session_handoff.dart';

void main() {
  group('GroupSessionHandoff', () {
    test('parse inline handoff with top-level fields', () {
      final parsed = GroupSessionHandoff.parse(
        inlineHandoff: {
          'task': {
            'user_goal': 'Implement pagination API',
            'acceptance_criteria': ['OpenAPI updated', 'Tests pass'],
            'status': 'in_progress',
          },
          'reason': {'code': 'topic_shift', 'detail': 'New scope'},
        },
        sourceSessionId: 'group_old',
        createdByAgentId: 'admin-1',
        createdByAgentName: 'PM',
      );
      expect(parsed.error, isNull);
      expect(parsed.handoff, isNotNull);
      expect(parsed.handoff!.userGoal, contains('pagination'));
      expect(parsed.handoff!.acceptanceCriteria, hasLength(2));
      expect(parsed.handoff!.reasonCode, 'topic_shift');
      expect(parsed.handoff!.sourceSessionId, 'group_old');
    });

    test('rejects missing acceptance criteria', () {
      final parsed = GroupSessionHandoff.parse(
        inlineHandoff: {
          'task': {
            'user_goal': 'Do something',
            'acceptance_criteria': [],
            'status': 'in_progress',
          },
          'reason': {'code': 'topic_shift'},
        },
      );
      expect(parsed.handoff, isNull);
      expect(parsed.error, isNotNull);
    });

    test('formatFirstMessage includes goal and handoff uri', () {
      final handoff = GroupSessionHandoff(
        handoffId: 'ho_test',
        reasonCode: 'post_delivery',
        userGoal: 'Build v2 filter API',
        acceptanceCriteria: ['Backward compatible'],
        status: 'not_started',
        sourceSessionId: 'group_abc12345',
      );
      final text = handoff.formatFirstMessage(
        handoffUri: 'store://workspaces/dev/group_x/shared/handoffs/ho_test.md',
      );
      expect(text, contains('【任务继续'));
      expect(text, contains('Build v2 filter API'));
      expect(text, contains('Backward compatible'));
      expect(text, contains('store://workspaces/dev/group_x/shared/handoffs/ho_test.md'));
    });

    test('toJson round-trip', () {
      final original = GroupSessionHandoff(
        handoffId: 'ho_roundtrip',
        reasonCode: 'noise_reduction',
        reasonDetail: 'Too noisy',
        userGoal: 'Continue delivery',
        acceptanceCriteria: ['Review pass'],
        status: 'delivered',
        constraints: const ['Use PostgreSQL'],
        artifacts: const [
          GroupSessionHandoffArtifact(
            uri: 'store://workspaces/dev/group_1/shared/design.md',
            label: 'Design',
          ),
        ],
      );
      final decoded = GroupSessionHandoff.fromJson(original.toJson());
      expect(decoded, isNotNull);
      expect(decoded!.handoffId, 'ho_roundtrip');
      expect(decoded.constraints, ['Use PostgreSQL']);
      expect(decoded.artifacts.single.label, 'Design');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_member_session_service.dart';

void main() {
  group('pendingRemoteResets (M6)', () {
    setUp(() => GroupMemberSessionService.pendingRemoteResets.clear());

    test('consume returns true once then removes the marker', () {
      const id = 'gmd_group_1__agent_a';
      GroupMemberSessionService.pendingRemoteResets.add(id);

      expect(
        GroupMemberSessionService.consumePendingRemoteReset(id),
        isTrue,
      );
      expect(
        GroupMemberSessionService.consumePendingRemoteReset(id),
        isFalse,
      );
      expect(GroupMemberSessionService.pendingRemoteResets, isEmpty);
    });

    test('consume on missing marker returns false', () {
      expect(
        GroupMemberSessionService.consumePendingRemoteReset('gmd_nope__x'),
        isFalse,
      );
    });

    test('memberSessionId is deterministic', () {
      expect(
        GroupMemberSessionService.memberSessionId('group_1', 'agent_a'),
        'gmd_group_1__agent_a',
      );
    });
  });
}

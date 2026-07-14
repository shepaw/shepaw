import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/group/group_member_session_service.dart';

void main() {
  group('GroupMemberSessionService helpers', () {
    test('memberSessionId is deterministic and unique per pair', () {
      final a = GroupMemberSessionService.memberSessionId('group_abc', 'agent_1');
      final b = GroupMemberSessionService.memberSessionId('group_abc', 'agent_1');
      final c = GroupMemberSessionService.memberSessionId('group_abc', 'agent_2');
      final d = GroupMemberSessionService.memberSessionId('group_xyz', 'agent_1');

      expect(a, b);
      expect(a, 'gmd_group_abc__agent_1');
      expect(a, isNot(c));
      expect(a, isNot(d));
    });

    test('memberSessionTitle includes group name and child short id', () {
      expect(
        GroupMemberSessionService.memberSessionTitle(
          groupName: 'Team',
          groupChannelId: 'group_parent',
        ),
        'Group · Team',
      );

      expect(
        GroupMemberSessionService.memberSessionTitle(
          groupName: 'Team',
          groupChannelId: 'group_abcdef123456',
          parentGroupId: 'group_parent',
        ),
        'Group · Team (#123456)',
      );
    });

    test('Channel.isGroupBoundMemberSession', () {
      final bound = Channel(
        id: 'gmd_group_1__agent_1',
        name: 'Group · Team',
        type: 'dm',
        members: const [],
        sourceGroupChannelId: 'group_1',
      );
      final personal = Channel(
        id: 'dm_user_agent',
        name: 'Chat',
        type: 'dm',
        members: const [],
      );
      final group = Channel(
        id: 'group_1',
        name: 'Team',
        type: 'group',
        members: const [],
        sourceGroupChannelId: 'should_ignore',
      );

      expect(bound.isGroupBoundMemberSession, isTrue);
      expect(personal.isGroupBoundMemberSession, isFalse);
      expect(group.isGroupBoundMemberSession, isFalse);
    });
  });
}

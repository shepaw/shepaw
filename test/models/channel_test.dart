import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';

void main() {
  group('ChannelMember Tests', () {
    test('should create member with required fields', () {
      final member = ChannelMember(
        id: 'user-1',
        type: 'user',
        role: 'member',
        joinedAt: 1700000000000,
      );

      expect(member.id, 'user-1');
      expect(member.type, 'user');
      expect(member.role, 'member');
      expect(member.joinedAt, 1700000000000);
      expect(member.groupBio, isNull);
    });

    test('isAgent and isUser should return correct values', () {
      final userMember = ChannelMember(
        id: 'u1', type: 'user', role: 'member', joinedAt: 0,
      );
      expect(userMember.isUser, true);
      expect(userMember.isAgent, false);

      final agentMember = ChannelMember(
        id: 'a1', type: 'agent', role: 'member', joinedAt: 0,
      );
      expect(agentMember.isAgent, true);
      expect(agentMember.isUser, false);
    });

    test('fromJson should parse correctly', () {
      final json = {
        'id': 'agent-1',
        'type': 'agent',
        'role': 'admin',
        'joined_at': 1700000000000,
        'group_bio': 'Custom bio for this group',
      };

      final member = ChannelMember.fromJson(json);

      expect(member.id, 'agent-1');
      expect(member.type, 'agent');
      expect(member.role, 'admin');
      expect(member.joinedAt, 1700000000000);
      expect(member.groupBio, 'Custom bio for this group');
    });

    test('fromJson should handle missing fields', () {
      final member = ChannelMember.fromJson({});

      expect(member.id, '');
      expect(member.type, 'user');
      expect(member.role, 'member');
      expect(member.joinedAt, 0);
      expect(member.groupBio, isNull);
    });

    test('toJson should produce correct output', () {
      final member = ChannelMember(
        id: 'u1',
        type: 'user',
        role: 'admin',
        joinedAt: 1700000000000,
        groupBio: 'A helpful assistant',
      );

      final json = member.toJson();

      expect(json['id'], 'u1');
      expect(json['type'], 'user');
      expect(json['role'], 'admin');
      expect(json['joined_at'], 1700000000000);
      expect(json['group_bio'], 'A helpful assistant');
    });

    test('toJson should omit groupBio when null', () {
      final member = ChannelMember(
        id: 'u1', type: 'user', role: 'member', joinedAt: 0,
      );

      final json = member.toJson();
      expect(json.containsKey('group_bio'), false);
    });
  });

  group('Channel Tests', () {
    late Channel dmChannel;
    late Channel groupChannel;

    setUp(() {
      dmChannel = Channel(
        id: 'dm_user1_agent1',
        name: 'Chat with Bot',
        type: 'dm',
        members: [
          ChannelMember(id: 'user-1', type: 'user', role: 'member', joinedAt: 0),
          ChannelMember(id: 'agent-1', type: 'agent', role: 'member', joinedAt: 0),
        ],
        createdBy: 'user-1',
        createdAt: 1700000000000,
      );

      groupChannel = Channel(
        id: 'group_abc123',
        name: 'Team Chat',
        type: 'group',
        members: [
          ChannelMember(id: 'user-1', type: 'user', role: 'member', joinedAt: 0),
          ChannelMember(id: 'agent-1', type: 'agent', role: 'admin', joinedAt: 0),
          ChannelMember(
            id: 'agent-2',
            type: 'agent',
            role: 'member',
            joinedAt: 0,
            groupBio: 'Translator',
          ),
        ],
        createdBy: 'user-1',
        createdAt: 1700000000000,
        description: 'A team group',
        systemPrompt: 'Be helpful',
      );
    });

    test('isDM, isGroup, isPublic should return correct values', () {
      expect(dmChannel.isDM, true);
      expect(dmChannel.isGroup, false);
      expect(dmChannel.isPublic, false);

      expect(groupChannel.isDM, false);
      expect(groupChannel.isGroup, true);
      expect(groupChannel.isPublic, false);

      final publicCh = Channel(
        id: 'pub-1', name: 'Public', type: 'public', members: [],
      );
      expect(publicCh.isPublic, true);
    });

    test('memberCount should return correct count', () {
      expect(dmChannel.memberCount, 2);
      expect(groupChannel.memberCount, 3);
    });

    test('agentIds should return only agent member IDs', () {
      expect(dmChannel.agentIds, ['agent-1']);
      expect(groupChannel.agentIds, ['agent-1', 'agent-2']);
    });

    test('memberIds should return all member IDs', () {
      expect(dmChannel.memberIds, ['user-1', 'agent-1']);
      expect(groupChannel.memberIds, ['user-1', 'agent-1', 'agent-2']);
    });

    test('adminAgentId should return admin or null', () {
      expect(dmChannel.adminAgentId, isNull);
      expect(groupChannel.adminAgentId, 'agent-1');
    });

    test('isAdmin should check admin role correctly', () {
      expect(groupChannel.isAdmin('agent-1'), true);
      expect(groupChannel.isAdmin('agent-2'), false);
      expect(groupChannel.isAdmin('user-1'), false);
    });

    test('getGroupBio should return bio for member', () {
      expect(groupChannel.getGroupBio('agent-2'), 'Translator');
      expect(groupChannel.getGroupBio('agent-1'), isNull);
      expect(groupChannel.getGroupBio('nonexistent'), isNull);
    });

    test('groupFamilyId for parent group should be its own id', () {
      expect(groupChannel.groupFamilyId, 'group_abc123');
    });

    test('groupFamilyId for child session should be parentGroupId', () {
      final childChannel = Channel(
        id: 'group_child1',
        name: 'Session',
        type: 'group',
        members: [],
        parentGroupId: 'group_abc123',
      );
      expect(childChannel.groupFamilyId, 'group_abc123');
    });

    group('Channel.withMemberIds factory', () {
      test('should create channel with member IDs', () {
        final ch = Channel.withMemberIds(
          id: 'test-ch',
          name: 'Test',
          type: 'group',
          memberIds: ['user-1', 'user-2'],
          systemPrompt: 'Be nice',
        );

        expect(ch.id, 'test-ch');
        expect(ch.members.length, 2);
        expect(ch.members[0].id, 'user-1');
        expect(ch.members[0].type, 'user');
        expect(ch.members[0].role, 'member');
        expect(ch.systemPrompt, 'Be nice');
      });
    });

    group('JSON serialization', () {
      test('fromJson should parse correctly', () {
        final json = {
          'id': 'group_xyz',
          'name': 'My Group',
          'type': 'group',
          'members': [
            {'id': 'u1', 'type': 'user', 'role': 'member', 'joined_at': 0},
            {'id': 'a1', 'type': 'agent', 'role': 'admin', 'joined_at': 100},
          ],
          'created_by': 'u1',
          'created_at': 1700000000000,
          'metadata': {
            'description': 'Test group',
            'avatar': 'emoji',
            'system_prompt': 'Be helpful',
          },
          'is_private': false,
          'unread_count': 5,
          'parent_group_id': 'group_parent',
        };

        final ch = Channel.fromJson(json);

        expect(ch.id, 'group_xyz');
        expect(ch.name, 'My Group');
        expect(ch.type, 'group');
        expect(ch.members.length, 2);
        expect(ch.members[1].role, 'admin');
        expect(ch.createdBy, 'u1');
        expect(ch.createdAt, 1700000000000);
        expect(ch.description, 'Test group');
        expect(ch.avatar, 'emoji');
        expect(ch.systemPrompt, 'Be helpful');
        expect(ch.isPrivate, false);
        expect(ch.unreadCount, 5);
        expect(ch.parentGroupId, 'group_parent');
      });

      test('fromJson should handle missing fields', () {
        final ch = Channel.fromJson({});

        expect(ch.id, '');
        expect(ch.name, '');
        expect(ch.type, 'dm');
        expect(ch.members, isEmpty);
        expect(ch.isPrivate, true);
      });

      test('toJson should produce correct output', () {
        final json = groupChannel.toJson();

        expect(json['id'], 'group_abc123');
        expect(json['name'], 'Team Chat');
        expect(json['type'], 'group');
        expect((json['members'] as List).length, 3);
        expect(json['created_by'], 'user-1');
        expect(json['created_at'], 1700000000000);
        expect(json['metadata']['description'], 'A team group');
        expect(json['metadata']['system_prompt'], 'Be helpful');
        expect(json['is_private'], true);
      });

      test('toJson should omit optional null fields', () {
        final json = dmChannel.toJson();

        expect(json.containsKey('parent_group_id'), false);
        expect(json.containsKey('unread_count'), false);
      });
    });

    group('copyWith', () {
      test('should copy with changed fields', () {
        final updated = groupChannel.copyWith(
          name: 'Updated Name',
          description: 'New description',
          unreadCount: 10,
        );

        expect(updated.id, groupChannel.id);
        expect(updated.name, 'Updated Name');
        expect(updated.description, 'New description');
        expect(updated.unreadCount, 10);
        // Unchanged fields
        expect(updated.type, groupChannel.type);
        expect(updated.members.length, groupChannel.members.length);
        expect(updated.systemPrompt, groupChannel.systemPrompt);
      });

      test('should keep original values when no changes', () {
        final copy = groupChannel.copyWith();

        expect(copy.id, groupChannel.id);
        expect(copy.name, groupChannel.name);
        expect(copy.type, groupChannel.type);
      });
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/hub_group_cache.dart';

void main() {
  test('hub group json becomes a channel the app can store', () {
    final channel = channelFromHubGroup({
      'id': 'group_1',
      'name': '重构小组',
      'type': 'group',
      'created_by': 'user',
      'created_at': 10,
      'flow_mode': true,
      'metadata': {
        'description': '改结构',
        'system_prompt': '',
        'mention_mode': 'allMembers',
        'max_loop_rounds': 0,
        'avatar': '🎯',
      },
      'members': [
        {'id': 'user', 'type': 'user', 'role': 'member', 'joined_at': 1},
        {
          'id': 'she-builtin-agent-001',
          'type': 'agent',
          'role': 'admin',
          'joined_at': 1,
          'group_bio': '管家',
        },
      ],
    });

    expect(channel.id, 'group_1');
    expect(channel.name, '重构小组');
    expect(channel.isGroup, isTrue);
    expect(channel.description, '改结构');
    expect(channel.systemPrompt, isNull);
    expect(channel.maxLoopRounds, isNull);
    expect(channel.mentionMode, 'allMembers');
    expect(channel.flowMode, isTrue);
    expect(channel.avatar, '🎯');
    expect(channel.adminAgentId, 'she-builtin-agent-001');
    expect(
      channel.members.firstWhere((m) => m.id == 'she-builtin-agent-001').groupBio,
      '管家',
    );
  });

  test('groups missing from the hub list are stale', () {
    expect(
      staleGroupIds(
        ['group_a', 'group_b'],
        [
          {'id': 'group_b'},
          {'id': 'group_c'},
        ],
      ),
      {'group_a'},
    );
  });
}

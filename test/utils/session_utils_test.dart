import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/utils/session_utils.dart';
import 'package:shepaw/models/channel.dart';

void main() {
  group('SessionUtils Tests', () {
    group('shortSessionId', () {
      test('should return default for simple DM channel id', () {
        // dm_userId_agentId (3 parts)
        expect(
          SessionUtils.shortSessionId('dm_user1_agent1'),
          '#default',
        );
      });

      test('should extract last 6 chars for DM with timestamp', () {
        // dm_userId_agentId_timestamp (4+ parts)
        expect(
          SessionUtils.shortSessionId('dm_user1_agent1_1700000000000'),
          '#000000',
        );
      });

      test('should handle short timestamp suffix', () {
        expect(
          SessionUtils.shortSessionId('dm_user1_agent1_abc'),
          '#abc',
        );
      });

      test('should extract last 6 chars of uuid for group channel', () {
        // group_<uuid>
        expect(
          SessionUtils.shortSessionId('group_abc12345-6789-0def'),
          '#9-0def',
        );
      });

      test('should handle short group uuid', () {
        expect(
          SessionUtils.shortSessionId('group_ab'),
          '#ab',
        );
      });

      test('should return default for unknown format', () {
        expect(SessionUtils.shortSessionId('unknown'), '#default');
        expect(SessionUtils.shortSessionId('single'), '#default');
      });

      group('with groupChannel parameter', () {
        test('should return default for parent group channel', () {
          final channel = Channel(
            id: 'group_abc123',
            name: 'Test Group',
            type: 'group',
            members: [],
          );

          expect(
            SessionUtils.shortSessionId('group_abc123', groupChannel: channel),
            '#default',
          );
        });

        test('should not return default for child session', () {
          final childChannel = Channel(
            id: 'group_child1',
            name: 'Child Session',
            type: 'group',
            members: [],
            parentGroupId: 'group_parent',
          );

          // Has parentGroupId, so it's not the default session
          final result = SessionUtils.shortSessionId(
            'group_child1',
            groupChannel: childChannel,
          );
          expect(result, '#child1');
        });

        test('should not affect DM channels', () {
          final dmChannel = Channel(
            id: 'dm_user1_agent1',
            name: 'DM',
            type: 'dm',
            members: [],
          );

          // DM channel - isGroup is false, so the group logic won't apply
          expect(
            SessionUtils.shortSessionId('dm_user1_agent1', groupChannel: dmChannel),
            '#default',
          );
        });
      });
    });

    group('shouldPruneEmptySessionOnSwitch', () {
      test('switching to the same session never prunes', () {
        expect(
          SessionUtils.shouldPruneEmptySessionOnSwitch(
            currentChannelId: 'dm_user1_agent1_1700000000000',
            nextChannelId: 'dm_user1_agent1_1700000000000',
            isGroupMode: false,
            defaultDmChannelId: 'dm_agent1_user1',
          ),
          false,
        );
      });

      group('DM mode', () {
        test('prunes timestamped dm session created by 新建会话', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'dm_user1_agent1_1700000000000',
              nextChannelId: 'dm_user1_agent1_1700000000001',
              isGroupMode: false,
              defaultDmChannelId: 'dm_agent1_user1',
            ),
            true,
          );
        });

        test('keeps the default session (no timestamp)', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'dm_agent1_user1',
              nextChannelId: 'dm_user1_agent1_1700000000001',
              isGroupMode: false,
              defaultDmChannelId: 'dm_agent1_user1',
            ),
            false,
          );
        });

        test('keeps derived sessions (gmd_ member / psess_ sync / peer__ inbound)', () {
          for (final id in [
            'gmd_group_x__agent1',
            'psess_remote123',
            'peer__peer1__agent1',
          ]) {
            expect(
              SessionUtils.shouldPruneEmptySessionOnSwitch(
                currentChannelId: id,
                nextChannelId: 'dm_user1_agent1_1700000000001',
                isGroupMode: false,
                defaultDmChannelId: 'dm_agent1_user1',
              ),
              false,
              reason: '$id should not be pruned',
            );
          }
        });

        test('keeps session when default id unknown', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'dm_user1_agent1_1700000000000',
              nextChannelId: 'dm_user1_agent1_1700000000001',
              isGroupMode: false,
              defaultDmChannelId: null,
            ),
            false,
          );
        });
      });

      group('group mode', () {
        test('prunes child session with messages', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'group_child1',
              nextChannelId: 'group_child2',
              isGroupMode: true,
              groupFamilyId: 'group_parent',
            ),
            true,
          );
        });

        test('keeps the parent group session', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'group_parent',
              nextChannelId: 'group_child1',
              isGroupMode: true,
              groupFamilyId: 'group_parent',
            ),
            false,
          );
        });

        test('keeps session when family id unknown', () {
          expect(
            SessionUtils.shouldPruneEmptySessionOnSwitch(
              currentChannelId: 'group_child1',
              nextChannelId: 'group_child2',
              isGroupMode: true,
              groupFamilyId: null,
            ),
            false,
          );
        });
      });
    });

    group('splitFirstSentence', () {
      test('中文句号切分：首句含标点，剩余为后续内容', () {
        final r = SessionUtils.splitFirstSentence(
            '帮我整理一下文件。然后发给小张看看。');
        expect(r.first, '帮我整理一下文件。');
        expect(r.rest, '然后发给小张看看。');
      });

      test('问号/感叹号/省略号同样切分', () {
        expect(
          SessionUtils.splitFirstSentence('你好吗？我很好。').first,
          '你好吗？',
        );
        expect(
          SessionUtils.splitFirstSentence('太棒了！继续加油。').first,
          '太棒了！',
        );
        expect(
          SessionUtils.splitFirstSentence('然后呢…就没了。').first,
          '然后呢…',
        );
      });

      test('换行切分', () {
        final r = SessionUtils.splitFirstSentence('第一行内容\n第二行内容');
        expect(r.first, '第一行内容');
        expect(r.rest, '第二行内容');
      });

      test('无句末标点：整段归 first，rest 为空', () {
        final r = SessionUtils.splitFirstSentence('一段没有标点的长文本');
        expect(r.first, '一段没有标点的长文本');
        expect(r.rest, '');
      });

      test('首尾空白被去除', () {
        final r = SessionUtils.splitFirstSentence('  你好。  我很好。  ');
        expect(r.first, '你好。');
        expect(r.rest, '我很好。');
      });
    });
  });
}

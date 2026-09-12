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

    group('familyChannelId', () {
      test('group child session uses parentGroupId', () {
        final session = Channel(
          id: 'group_child-session',
          name: 'Child',
          type: 'group',
          members: const [],
          parentGroupId: 'group_family-root',
        );
        expect(SessionUtils.familyChannelId(session), 'group_family-root');
      });

      test('parent group session uses its own id', () {
        final session = Channel(
          id: 'group_family-root',
          name: 'Group',
          type: 'group',
          members: const [],
        );
        expect(SessionUtils.familyChannelId(session), 'group_family-root');
      });

      test('group-bound member DM uses sourceGroupChannelId', () {
        final session = Channel(
          id: 'gmd_group_x__agent1',
          name: 'Member DM',
          type: 'dm',
          members: const [],
          sourceGroupChannelId: 'group_family-root',
        );
        expect(SessionUtils.familyChannelId(session), 'group_family-root');
      });

      test('plain DM falls back to session id', () {
        final session = Channel(
          id: 'dm_user1_agent1_1700000000000',
          name: 'DM',
          type: 'dm',
          members: const [],
        );
        expect(
          SessionUtils.familyChannelId(session),
          'dm_user1_agent1_1700000000000',
        );
      });
    });

    group('sessionIdFromChannelId', () {
      test('strips psess_ prefix for synced peer sessions', () {
        expect(
          SessionUtils.sessionIdFromChannelId('psess_remote-session-42'),
          'remote-session-42',
        );
      });

      test('returns local channel id unchanged', () {
        expect(
          SessionUtils.sessionIdFromChannelId('dm_user1_agent1_1700000000000'),
          'dm_user1_agent1_1700000000000',
        );
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

    group('cleanClaudeSessionTitle & isClaudeCommandArtifact', () {
      test('isClaudeCommandArtifact 识别三个注入标签', () {
        expect(
          SessionUtils.isClaudeCommandArtifact(
            '<local-command-caveat>Caveat: xxx</local-command-caveat>',
          ),
          isTrue,
        );
        expect(
          SessionUtils.isClaudeCommandArtifact('<command-name>/model</command-name>'),
          isTrue,
        );
        expect(
          SessionUtils.isClaudeCommandArtifact(
            '<local-command-stdout>Set model to A</local-command-stdout>',
          ),
          isTrue,
        );
      });

      test('isClaudeCommandArtifact 对普通文本返回 false', () {
        expect(SessionUtils.isClaudeCommandArtifact('修复登录 bug'), isFalse);
        expect(SessionUtils.isClaudeCommandArtifact(null), isFalse);
        expect(SessionUtils.isClaudeCommandArtifact(''), isFalse);
      });

      test('仅含 caveat 时清理为空，回落默认名', () {
        expect(
          SessionUtils.cleanClaudeSessionTitle(
            '<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>',
          ),
          isNull,
        );
      });

      test('清理 command-name 与 stdout，保留真实标题', () {
        expect(
          SessionUtils.cleanClaudeSessionTitle(
            '<command-name>/model</command-name>\n<local-command-stdout>Set model to deepseek/deepseek-v4-flash-0731[1m]</local-command-stdout>\n修复聊天指令',
          ),
          '修复聊天指令',
        );
      });

      test('折叠多余空白', () {
        expect(
          SessionUtils.cleanClaudeSessionTitle('  修复  bug   '),
          '修复 bug',
        );
      });

      test('null 输入返回 null', () {
        expect(SessionUtils.cleanClaudeSessionTitle(null), isNull);
      });
    });
  });
}

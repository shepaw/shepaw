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
          'Session #default',
        );
      });

      test('should extract last 6 chars for DM with timestamp', () {
        // dm_userId_agentId_timestamp (4+ parts)
        expect(
          SessionUtils.shortSessionId('dm_user1_agent1_1700000000000'),
          'Session #000000',
        );
      });

      test('should handle short timestamp suffix', () {
        expect(
          SessionUtils.shortSessionId('dm_user1_agent1_abc'),
          'Session #abc',
        );
      });

      test('should extract last 6 chars of uuid for group channel', () {
        // group_<uuid>
        expect(
          SessionUtils.shortSessionId('group_abc12345-6789-0def'),
          'Session #9-0def',
        );
      });

      test('should handle short group uuid', () {
        expect(
          SessionUtils.shortSessionId('group_ab'),
          'Session #ab',
        );
      });

      test('should return default for unknown format', () {
        expect(SessionUtils.shortSessionId('unknown'), 'Session #default');
        expect(SessionUtils.shortSessionId('single'), 'Session #default');
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
            'Session #default',
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
          expect(result, 'Session #child1');
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
            'Session #default',
          );
        });
      });
    });
  });
}

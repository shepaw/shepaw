import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/channel.dart';
import 'package:shepaw/services/hub_cli_execute.dart';

void main() {
  group('HubCliExecute.sanitizeFlags', () {
    test('drops forged identity fields and keeps the rest', () {
      final flags = HubCliExecute.sanitizeFlags({
        'uri': 'store://runtime/d/a/x',
        'agent_id': 'forged-agent',
        'owner': 'forged-owner',
        'channel_id': 'forged-channel',
        'channel': 'also-forged',
        'filename': 'notes.md',
      });
      expect(flags['uri'], 'store://runtime/d/a/x');
      expect(flags['filename'], 'notes.md');
      expect(flags.containsKey('agent_id'), isFalse);
      expect(flags.containsKey('owner'), isFalse);
      expect(flags.containsKey('channel_id'), isFalse);
      expect(flags.containsKey('channel'), isFalse);
    });

    test('empty or non-map flags become {}', () {
      expect(HubCliExecute.sanitizeFlags(null), isEmpty);
      expect(HubCliExecute.sanitizeFlags('x'), isEmpty);
    });
  });

  group('HubCliExecute.boundSessionId', () {
    test('reads session_id only', () {
      expect(
        HubCliExecute.boundSessionId({
          'session_id': 'sess-1',
          'channel_id': 'ignored',
        }),
        'sess-1',
      );
      expect(HubCliExecute.boundSessionId({'channel_id': 'nope'}), isNull);
      expect(HubCliExecute.boundSessionId({'session_id': '  '}), isNull);
    });
  });

  group('HubCliExecute.resolveSessionId', () {
    test('prefers explicit session_id over the in-flight fallback', () {
      expect(
        HubCliExecute.resolveSessionId(
          {'session_id': 'from-agent'},
          activeFallback: 'group-9',
        ),
        'from-agent',
      );
    });

    test('omitted session_id uses the in-flight group/DM turn', () {
      expect(
        HubCliExecute.resolveSessionId({}, activeFallback: 'group-9'),
        'group-9',
      );
      expect(HubCliExecute.resolveSessionId({}), isNull);
    });
  });

  group('HubCliExecute.scopeOf', () {
    test('group-bound member session maps to the group bag', () {
      final ch = Channel.withMemberIds(
        id: 'dm-member',
        name: 'Member',
        type: 'dm',
        memberIds: ['user-1', 'agent-1'],
        sourceGroupChannelId: 'group-9',
      );
      expect(HubCliExecute.isMember(ch, 'agent-1'), isTrue);
      expect(HubCliExecute.isMember(ch, 'stranger'), isFalse);
      final scope = HubCliExecute.scopeOf(ch, 'agent-1');
      expect(scope.channelId, 'group-9');
      expect(scope.runtimeOwnerId, 'group-9');
    });

    test('plain DM keeps the session channel', () {
      final ch = Channel.withMemberIds(
        id: 'dm-1',
        name: 'DM',
        type: 'dm',
        memberIds: ['user-1', 'agent-1'],
      );
      final scope = HubCliExecute.scopeOf(ch, 'agent-1');
      expect(scope.channelId, 'dm-1');
      expect(scope.runtimeOwnerId, 'agent-1');
    });
  });
}

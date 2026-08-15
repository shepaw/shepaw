import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/mailbox_reply_router.dart';

void main() {
  group('resolveMailboxReplyDestination', () {
    test('routes group_id to that channel when it exists', () {
      final dest = resolveMailboxReplyDestination(
        groupId: 'group_abc',
        fallbackChannelId: 'dm_first',
        groupChannelExists: (id) => id == 'group_abc',
      );
      expect(dest, 'group_abc');
    });

    test('does not fall back to DM when group_id is set but channel is missing',
        () {
      final dest = resolveMailboxReplyDestination(
        groupId: 'group_missing',
        fallbackChannelId: 'dm_first',
        groupChannelExists: (_) => false,
      );
      expect(dest, isNull);
    });

    test('uses fallback DM when group_id is empty', () {
      final dest = resolveMailboxReplyDestination(
        groupId: '',
        fallbackChannelId: 'dm_first',
        groupChannelExists: (_) => true,
      );
      expect(dest, 'dm_first');
    });

    test('skips when group_id and fallback are both empty', () {
      final dest = resolveMailboxReplyDestination(
        groupId: '',
        fallbackChannelId: null,
        groupChannelExists: (_) => true,
      );
      expect(dest, isNull);
    });
  });

  group('mailboxReplyGroupId', () {
    test('prefers payload group_id over envelope', () {
      expect(
        mailboxReplyGroupId(
          replyGroupId: 'envelope',
          payload: {'group_id': 'payload_group'},
        ),
        'payload_group',
      );
    });

    test('falls back to envelope when payload has no group_id', () {
      expect(
        mailboxReplyGroupId(replyGroupId: 'envelope', payload: {}),
        'envelope',
      );
    });
  });
}

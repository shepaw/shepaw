import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/group/group_mailbox_save_plan.dart';

Message _mailboxReply() => Message(
      id: 'inbox_msg-user-1',
      content: 'reply content',
      timestampMs: 1,
      from: MessageFrom(id: 'agent-1', type: 'agent', name: 'Agent One'),
      type: MessageType.text,
      metadata: {
        'status': 'completed',
        'from_mailbox': true,
        'mailbox_entry_id': 'mb_42',
        'request_id': 'req-1',
        'session_id': 'sess-1',
        'group_id': 'grp-1',
      },
    );

void main() {
  group('GroupMailboxSavePlan.messageIdFor', () {
    test('uses the mailbox reply id for deterministic dedupe', () {
      expect(
        GroupMailboxSavePlan.messageIdFor(_mailboxReply(), 'fallback-uuid'),
        'inbox_msg-user-1',
      );
    });

    test('null left keeps the generated fallback id', () {
      expect(
        GroupMailboxSavePlan.messageIdFor(null, 'fallback-uuid'),
        'fallback-uuid',
      );
    });
  });

  group('GroupMailboxSavePlan.mergeMetadata', () {
    test('merges whitelisted mailbox keys', () {
      final merged = GroupMailboxSavePlan.mergeMetadata({}, _mailboxReply());

      expect(merged['from_mailbox'], isTrue);
      expect(merged['mailbox_entry_id'], 'mb_42');
      expect(merged['request_id'], 'req-1');
      expect(merged['session_id'], 'sess-1');
      expect(merged['group_id'], 'grp-1');
    });

    test('does not leak the status key', () {
      final merged = GroupMailboxSavePlan.mergeMetadata({}, _mailboxReply());
      expect(merged.containsKey('status'), isFalse);
    });

    test('null left keeps base metadata untouched', () {
      final base = <String, dynamic>{'trace_id': 'trace-1'};
      final merged = GroupMailboxSavePlan.mergeMetadata(base, null);

      expect(merged, {'trace_id': 'trace-1'});
    });

    test('existing keys such as trace_id are preserved', () {
      final base = <String, dynamic>{
        'trace_id': 'trace-1',
        'progress_content': 'working…',
      };
      final merged = GroupMailboxSavePlan.mergeMetadata(base, _mailboxReply());

      expect(merged['trace_id'], 'trace-1');
      expect(merged['progress_content'], 'working…');
      expect(merged['mailbox_entry_id'], 'mb_42');
    });
  });
}

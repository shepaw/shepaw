import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/channel_mailbox_service.dart';

void main() {
  test('MailboxReply.fromJson parses inbox correlation fields', () {
    final reply = MailboxReply.fromJson({
      'id': 'mb_1',
      'message_id': 'req-1:final',
      'reply_to': 'msg-user-1',
      'request_id': 'req-1',
      'session_id': 'sess-1',
      'group_id': 'grp-1',
      'target_id': 'acp_agent_abcd',
      'kind': 'chat',
      'ciphertext': 'sealed',
      'created_at': '2026-08-14T12:00:00Z',
    });

    expect(reply.requestId, 'req-1');
    expect(reply.targetId, 'acp_agent_abcd');
    expect(reply.groupId, 'grp-1');
    expect(reply.kind, 'chat');
    expect(reply.replyTo, 'msg-user-1');
  });

  test('MailboxReply.fromJson falls back to agent_id for legacy payloads', () {
    final reply = MailboxReply.fromJson({
      'id': 'mb_2',
      'message_id': 'm2',
      'agent_id': 'acp_agent_legacy',
      'ciphertext': 'sealed',
    });

    expect(reply.targetId, 'acp_agent_legacy');
    expect(reply.kind, 'chat');
  });
}

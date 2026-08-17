import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/mailbox/channel_mailbox_service.dart';
import 'package:shepaw/services/mailbox/mailbox_turn_claims.dart';

MailboxReply _reply({
  String id = 'mb_1',
  String requestId = 'req-1',
  String replyTo = 'msg-1',
  String kind = 'chat',
}) =>
    MailboxReply(
      id: id,
      messageId: '$requestId:final',
      replyTo: replyTo,
      requestId: requestId,
      sessionId: 'sess-1',
      groupId: '',
      targetId: 'agent-a',
      kind: kind,
      ciphertext: 'sealed',
      createdAt: '2026-08-17T00:00:00Z',
    );

void main() {
  group('MailboxTurnClaims', () {
    test('claim matches by requestId', () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      expect(
        claims.isClaimed('agent-a', requestId: 'req-1', replyTo: ''),
        isTrue,
      );
    });

    test('claim matches by replyTo == userMessageId', () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      expect(
        claims.isClaimed('agent-a', requestId: '', replyTo: 'msg-1'),
        isTrue,
      );
    });

    test('no match for a different agentId', () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      expect(
        claims.isClaimed('agent-b', requestId: 'req-1', replyTo: 'msg-1'),
        isFalse,
      );
    });

    test('empty requestId and replyTo never match', () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      expect(claims.isClaimed('agent-a', requestId: '', replyTo: ''), isFalse);
    });

    test('release removes only the released turn when two turns share an agent',
        () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      claims.claim('agent-a', 'req-2', 'msg-2');

      claims.release('agent-a', 'req-1', 'msg-1');

      expect(
        claims.isClaimed('agent-a', requestId: 'req-1', replyTo: 'msg-1'),
        isFalse,
      );
      expect(
        claims.isClaimed('agent-a', requestId: 'req-2', replyTo: 'msg-2'),
        isTrue,
      );
    });

    test('release of unknown claim is a no-op', () {
      final claims = MailboxTurnClaims();
      expect(
        () => claims.release('agent-a', 'req-x', 'msg-x'),
        returnsNormally,
      );
    });

    test('re-claim after release works', () {
      final claims = MailboxTurnClaims();
      claims.claim('agent-a', 'req-1', 'msg-1');
      claims.release('agent-a', 'req-1', 'msg-1');
      claims.claim('agent-a', 'req-1', 'msg-1');
      expect(
        claims.isClaimed('agent-a', requestId: 'req-1', replyTo: ''),
        isTrue,
      );
    });
  });

  group('MailboxReplyPrefilter', () {
    test('claimed final reply is skipped without ack', () {
      final claims = MailboxTurnClaims()..claim('agent-a', 'req-1', 'msg-1');
      final action = MailboxReplyPrefilter.classify(
        _reply(kind: 'chat'),
        'agent-a',
        claims,
      );
      expect(action, MailboxReplyAction.claimedSkip);
    });

    test('claimed stream chunk is NOT orphan-acked', () {
      // 回归守卫：认领检查必须先于 orphan-stream ack 分支，否则推送触发的
      // fetch 会把活跃轮次的流式片段当孤儿 ack 掉。
      final claims = MailboxTurnClaims()..claim('agent-a', 'req-1', 'msg-1');
      final action = MailboxReplyPrefilter.classify(
        _reply(kind: 'stream'),
        'agent-a',
        claims,
      );
      expect(action, MailboxReplyAction.claimedSkip);
    });

    test('unclaimed stream kind is orphan-acked', () {
      final claims = MailboxTurnClaims();
      final action = MailboxReplyPrefilter.classify(
        _reply(kind: 'stream'),
        'agent-a',
        claims,
      );
      expect(action, MailboxReplyAction.orphanStreamAck);
    });

    test('unclaimed final proceeds to decrypt', () {
      final claims = MailboxTurnClaims();
      final action = MailboxReplyPrefilter.classify(
        _reply(kind: 'chat'),
        'agent-a',
        claims,
      );
      expect(action, MailboxReplyAction.process);
    });
  });
}

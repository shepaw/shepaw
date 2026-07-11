import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/dm_send_turn_planner.dart';

void main() {
  group('HistoryRequestInfo', () {
    test('parses defaults', () {
      final info = HistoryRequestInfo.fromMap({});
      expect(info.reason, 'Agent needs more context');
      expect(info.requestId, '');
      expect(info.requestedCount, 40);
    });

    test('parses explicit fields', () {
      final info = HistoryRequestInfo.fromMap({
        'reason': 'need more',
        'request_id': 'r1',
        'requested_count': 80,
      });
      expect(info.reason, 'need more');
      expect(info.requestId, 'r1');
      expect(info.requestedCount, 80);
    });
  });

  group('DmSendTurnPlanner.buildOptimisticPair', () {
    test('builds user + streaming bubbles with shared timestamp base', () {
      final pair = DmSendTurnPlanner.buildOptimisticPair(
        content: 'hello',
        userId: 'u',
        userName: 'User',
        agentId: 'a',
        agentName: 'Agent',
        replyToId: 'prev',
        nowMs: 1000,
      );
      expect(pair.user.id, 'temp_user_1000');
      expect(pair.user.content, 'hello');
      expect(pair.user.replyTo, 'prev');
      expect(pair.streaming.id, 'streaming_1000');
      expect(pair.streaming.content, isEmpty);
      expect(pair.streaming.from.id, 'a');
      expect(pair.streaming.timestampMs, 1001);
    });
  });

  group('DmSendTurnPlanner.evaluateSupplementRound', () {
    test('null supplement → noMoreHistory', () {
      final d = DmSendTurnPlanner.evaluateSupplementRound(
        supplementIsNull: true,
        actualSentCount: 0,
        messageContent: '',
      );
      expect(d.action, HistorySupplementRoundAction.noMoreHistory);
    });

    test('pending history → needMoreHistory and delete empty', () {
      final d = DmSendTurnPlanner.evaluateSupplementRound(
        supplementIsNull: false,
        actualSentCount: 12,
        messageContent: '',
        pendingHistoryRequest: {
          'reason': 'still short',
          'requested_count': 60,
        },
      );
      expect(d.action, HistorySupplementRoundAction.needMoreHistory);
      expect(d.actualSentCount, 12);
      expect(d.nextReason, 'still short');
      expect(d.nextRequestedCount, 60);
      expect(d.deleteEmptySupplementMessage, isTrue);
    });

    test('no pending → reanswerReady', () {
      final d = DmSendTurnPlanner.evaluateSupplementRound(
        supplementIsNull: false,
        actualSentCount: 5,
        messageContent: 'ok',
      );
      expect(d.action, HistorySupplementRoundAction.reanswerReady);
      expect(d.actualSentCount, 5);
    });
  });

  group('DmSendTurnPlanner.afterAgentSend', () {
    test('async with active task awaits and skips reload', () {
      final d = DmSendTurnPlanner.afterAgentSend(
        supportsAsyncConfirmation: true,
        hasChannel: true,
        hasActiveTask: true,
        handledHistorySupplement: false,
        agentResponseIsNull: true,
      );
      expect(d.awaitingAsyncTask, isTrue);
      expect(d.loadMessagesNow, isFalse);
      expect(d.showNullResponseError, isFalse);
    });

    test('sync null response shows error', () {
      final d = DmSendTurnPlanner.afterAgentSend(
        supportsAsyncConfirmation: false,
        hasChannel: true,
        hasActiveTask: false,
        handledHistorySupplement: false,
        agentResponseIsNull: true,
      );
      expect(d.awaitingAsyncTask, isFalse);
      expect(d.loadMessagesNow, isTrue);
      expect(d.showNullResponseError, isTrue);
    });

    test('history supplement suppresses null error', () {
      final d = DmSendTurnPlanner.afterAgentSend(
        supportsAsyncConfirmation: false,
        hasChannel: true,
        hasActiveTask: false,
        handledHistorySupplement: true,
        agentResponseIsNull: true,
      );
      expect(d.showNullResponseError, isFalse);
    });
  });
}

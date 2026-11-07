import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/dm_send_turn_planner.dart';
import 'package:shepaw/models/client_device_info.dart';
import 'package:shepaw/models/message.dart';

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

    test('uses explicit userMessageId when provided', () {
      final pair = DmSendTurnPlanner.buildOptimisticPair(
        content: 'hello',
        userId: 'u',
        userName: 'User',
        agentId: 'a',
        agentName: 'Agent',
        userMessageId: 'uuid-user-123',
        nowMs: 1000,
      );
      expect(pair.user.id, 'uuid-user-123');
      expect(pair.streaming.id, 'streaming_1000');
    });

    test('instructionName attaches metadata to user bubble', () {
      final pair = DmSendTurnPlanner.buildOptimisticPair(
        content: '执行指令「沉淀指令」：\n内容',
        userId: 'u',
        userName: 'User',
        agentId: 'a',
        agentName: 'Agent',
        instructionName: '沉淀指令',
        nowMs: 2000,
      );
      expect(pair.user.metadata?['instruction'], '沉淀指令');
      // 无 instructionName 时不带指令 metadata。
      final plain = DmSendTurnPlanner.buildOptimisticPair(
        content: '普通',
        userId: 'u',
        userName: 'User',
        agentId: 'a',
        agentName: 'Agent',
        nowMs: 3000,
      );
      expect(plain.user.metadata?['instruction'], isNull);
      expect(
        plain.user.metadata?[ClientDeviceInfo.deviceFormMetaKey],
        isNotEmpty,
      );
      expect(
        plain.user.metadata?[ClientDeviceInfo.deviceNameMetaKey],
        isNotEmpty,
      );
    });
  });

  group('DmSendTurnPlanner.placeStreamingAfterUser', () {
    Message text(String id, int at, {bool agent = false}) => Message(
          id: id,
          content: id,
          timestampMs: at,
          from: MessageFrom(
            id: agent ? 'a' : 'u',
            type: agent ? 'agent' : 'user',
            name: agent ? 'Agent' : 'User',
          ),
          type: MessageType.text,
        );

    test('占位紧跟在自己的用户消息后面，不盖住后发出去的消息', () {
      final user = text('u1', 10);
      final later = text('u2', 20);
      final streaming = text('s1', 11, agent: true);
      final messages = <Message>[user, later, streaming];

      DmSendTurnPlanner.placeStreamingAfterUser(
        messages: messages,
        user: user,
        streaming: streaming,
      );

      expect(messages.map((m) => m.id).toList(), ['u1', 's1', 'u2']);
    });

    test('排队时撤掉还没内容的占位，已经写出的正文留下', () {
      final empty = Message(
        id: 's-empty',
        content: '',
        timestampMs: 1,
        from: MessageFrom(id: 'a', type: 'agent', name: 'Agent'),
        type: MessageType.text,
      );
      final filled = text('s-filled', 2, agent: true);
      final messages = <Message>[empty, filled];

      expect(
        DmSendTurnPlanner.dropEmptyStreamingPlaceholder(
          messages: messages,
          streamingId: 's-empty',
        ),
        isTrue,
      );
      expect(
        DmSendTurnPlanner.dropEmptyStreamingPlaceholder(
          messages: messages,
          streamingId: 's-filled',
        ),
        isFalse,
      );
      expect(messages.map((m) => m.id).toList(), ['s-filled']);
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

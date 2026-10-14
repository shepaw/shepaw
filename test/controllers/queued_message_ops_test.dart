import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/queued_message_ops.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/mention_entry.dart';
import 'package:shepaw/models/queued_message.dart';

QueuedMessage _msg(String id, String content) =>
    QueuedMessage(id: id, content: content);

AttachmentData _attachment(String name) => AttachmentData(
      fileName: name,
      mimeType: 'application/octet-stream',
      sizeBytes: 1,
      bytes: Uint8List(1),
      semanticType: 'file',
    );

void main() {
  group('QueuedMessageOps.edit', () {
    test('hits by id and trims content', () {
      final q = [_msg('a', 'hello'), _msg('b', 'world')];
      expect(QueuedMessageOps.edit(q, 'a', '  edited  '), isTrue);
      expect(q.first.content, 'edited');
      expect(q.last.content, 'world');
    });

    test('rejects empty trimmed content (returns false, unchanged)', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.edit(q, 'a', '   '), isFalse);
      expect(q.first.content, 'hello');
    });

    test('returns false when id not found', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.edit(q, 'nope', 'x'), isFalse);
      expect(q.first.content, 'hello');
    });
  });

  group('QueuedMessageOps.remove', () {
    test('removes by id', () {
      final q = [_msg('a', 'hello'), _msg('b', 'world')];
      expect(QueuedMessageOps.remove(q, 'a'), isTrue);
      expect(q.map((m) => m.id), ['b']);
    });

    test('returns false when id not found', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.remove(q, 'nope'), isFalse);
      expect(q.length, 1);
    });

    test('removing the last element works', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.remove(q, 'a'), isTrue);
      expect(q, isEmpty);
    });
  });

  group('QueuedMessageOps.move', () {
    test('moves up (delta -1)', () {
      final q = [_msg('a', '1'), _msg('b', '2'), _msg('c', '3')];
      expect(QueuedMessageOps.move(q, 'b', -1), isTrue);
      expect(q.map((m) => m.id), ['b', 'a', 'c']);
    });

    test('moves down (delta +1)', () {
      final q = [_msg('a', '1'), _msg('b', '2'), _msg('c', '3')];
      expect(QueuedMessageOps.move(q, 'a', 1), isTrue);
      expect(q.map((m) => m.id), ['b', 'a', 'c']);
    });

    test('clamps at boundaries (returns false)', () {
      final q = [_msg('a', '1'), _msg('b', '2')];
      expect(QueuedMessageOps.move(q, 'a', -1), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
      expect(QueuedMessageOps.move(q, 'b', 1), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
    });

    test('returns false when id not found', () {
      final q = [_msg('a', '1')];
      expect(QueuedMessageOps.move(q, 'nope', -1), isFalse);
    });

    test('returns false when delta is 0', () {
      final q = [_msg('a', '1'), _msg('b', '2')];
      expect(QueuedMessageOps.move(q, 'a', 0), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
    });
  });

  group('QueuedMessageOps.buildRestorePayload', () {
    test('failed content first, then queue in send order, trimmed', () {
      final q = [_msg('a', '  hello '), _msg('b', 'world')];
      final payload = QueuedMessageOps.buildRestorePayload(
        queue: q,
        failedContent: '  failed  ',
      );
      expect(payload.parts, ['failed', 'hello', 'world']);
      expect(payload.attachments, isEmpty);
    });

    test('filters empty / whitespace-only content', () {
      final q = [_msg('a', ''), _msg('b', '   '), _msg('c', 'keep')];
      final payload = QueuedMessageOps.buildRestorePayload(
        queue: q,
        failedContent: '   ',
      );
      expect(payload.parts, ['keep']);
    });

    test('collects attachments failed-first then queue in order', () {
      final failedAtt = _attachment('failed.bin');
      final queuedAtt = _attachment('queued.bin');
      final q = [
        QueuedMessage(id: 'a', content: 'with att', attachments: [queuedAtt]),
        _msg('b', 'plain'),
      ];
      final payload = QueuedMessageOps.buildRestorePayload(
        queue: q,
        failedContent: 'x',
        failedAttachments: [failedAtt],
      );
      expect(payload.parts, ['x', 'with att', 'plain']);
      expect(payload.attachments.map((a) => a.fileName),
          ['failed.bin', 'queued.bin']);
    });

    test('both lists empty when nothing to restore', () {
      final empty = QueuedMessageOps.buildRestorePayload(
        queue: [],
        failedContent: null,
      );
      expect(empty.parts, isEmpty);
      expect(empty.attachments, isEmpty);
    });
  });

  group('takeQueuedMessage', () {
    test('removes the matching item and reports its channel', () {
      final queues = {
        'dm-1': [_msg('a', 'first'), _msg('b', 'second')],
        'dm-2': [_msg('c', 'other')],
      };
      final taken = takeQueuedMessage(queues, 'b');
      expect(taken?.channelId, 'dm-1');
      expect(taken?.message.content, 'second');
      expect(queues['dm-1']!.map((m) => m.id), ['a']);
      expect(queues['dm-2']!.map((m) => m.id), ['c']);
      expect(takeQueuedMessage(queues, 'b'), isNull);
      expect(takeQueuedMessage(queues, ''), isNull);
    });
  });

  group('QueuedMessage.toChatBubble', () {
    test('keeps the queue id and reply metadata', () {
      final item = QueuedMessage(
        id: 'queue-1',
        content: '接着说',
        replyToId: 'm-9',
        replyQuoteText: '上一句',
        instructionName: '日报',
        mentions: const [
          MentionEntry(id: 'agent-1', name: 'She', notify: true),
        ],
      );
      final bubble = item.toChatBubble(
        userId: 'user',
        userName: 'User',
        nowMs: 42,
      );
      expect(bubble.id, 'queue-1');
      expect(bubble.content, '接着说');
      expect(bubble.timestampMs, 42);
      expect(bubble.from.type, 'user');
      expect(bubble.replyTo, 'm-9');
      expect(bubble.metadata?['reply_quote'], '上一句');
      expect(bubble.metadata?['instruction'], '日报');
      expect(bubble.metadata?['mentions'], isNotEmpty);
    });
  });

  group('QueuedMessageOps.localQueueShouldSend', () {
    test('a message already on the host is not sent again', () {
      expect(QueuedMessageOps.localQueueShouldSend(hostOwned: true), isFalse);
      expect(QueuedMessageOps.localQueueShouldSend(hostOwned: false), isTrue);
    });
  });
}

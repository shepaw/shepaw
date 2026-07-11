import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_attachment_coordinator.dart';
import 'package:shepaw/controllers/chat_streaming_text.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/pending_attachment.dart';

void main() {
  group('PendingAttachmentQueue', () {
    test('rejects adds when full', () async {
      final queue = PendingAttachmentQueue(maxItems: 1);
      final file = File('${Directory.systemTemp.path}/att_q_test.txt')
        ..writeAsStringSync('x');
      addTearDown(() {
        try {
          file.deleteSync();
        } catch (_) {}
      });

      expect(await queue.addFromFile(file), isTrue);
      expect(queue.isFull, isTrue);
      expect(await queue.addFromFile(file), isFalse);
      expect(queue.length, 1);
    });

    test('remove deletes clipboard temps', () async {
      final temp = File(
        '${Directory.systemTemp.path}/clip_${DateTime.now().microsecondsSinceEpoch}.png',
      )..writeAsBytesSync([1, 2, 3]);
      final queue = PendingAttachmentQueue();
      final att = PendingAttachment(
        id: '1',
        file: temp,
        fileName: 'clip.png',
        fileSize: 3,
        type: PendingAttachmentType.image,
        isFromClipboard: true,
      );
      queue.items.add(att);
      queue.remove(att);
      expect(queue.isEmpty, isTrue);
      expect(temp.existsSync(), isFalse);
    });
  });

  group('ChatStreamingText', () {
    test('withStoppedMarker handles empty and non-empty', () {
      expect(ChatStreamingText.withStoppedMarker(''), '[Stopped]');
      expect(
        ChatStreamingText.withStoppedMarker('Hello'),
        'Hello\n\n[Stopped]',
      );
    });

    test('markMessageStopped preserves identity fields', () {
      final original = Message(
        id: 'm1',
        content: 'partial',
        timestampMs: 42,
        from: MessageFrom(id: 'a', type: 'agent', name: 'A'),
        to: MessageFrom(id: 'u', type: 'user', name: 'U'),
        channelId: 'ch',
        type: MessageType.text,
        metadata: {'k': 1},
      );
      final stopped = ChatStreamingText.markMessageStopped(original);
      expect(stopped.id, 'm1');
      expect(stopped.channelId, 'ch');
      expect(stopped.metadata?['k'], 1);
      expect(stopped.content, 'partial\n\n[Stopped]');
    });
  });
}

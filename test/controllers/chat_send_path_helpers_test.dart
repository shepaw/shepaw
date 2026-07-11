import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_send_planner.dart';
import 'package:shepaw/controllers/inbound_file_message_parser.dart';
import 'package:shepaw/controllers/streaming_action_confirmation.dart';
import 'package:shepaw/models/message.dart';

Message _agent(String id, {Map<String, dynamic>? metadata, String content = ''}) {
  return Message(
    id: id,
    content: content,
    timestampMs: 1,
    from: MessageFrom(id: 'a', type: 'agent', name: 'A'),
    to: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('ChatSendPlanner', () {
    test('empty / noAgent / attachmentsOnly / queue / routes', () {
      expect(
        ChatSendPlanner.decide(
          content: '',
          hasAttachments: false,
          isGroupMode: false,
          hasAgent: true,
          isProcessing: false,
        ),
        ChatSendDisposition.empty,
      );
      expect(
        ChatSendPlanner.decide(
          content: 'hi',
          hasAttachments: false,
          isGroupMode: false,
          hasAgent: false,
          isProcessing: false,
        ),
        ChatSendDisposition.noAgent,
      );
      expect(
        ChatSendPlanner.decide(
          content: '',
          hasAttachments: true,
          isGroupMode: false,
          hasAgent: true,
          isProcessing: false,
        ),
        ChatSendDisposition.attachmentsOnly,
      );
      expect(
        ChatSendPlanner.decide(
          content: 'hi',
          hasAttachments: true,
          isGroupMode: false,
          hasAgent: true,
          isProcessing: true,
        ),
        ChatSendDisposition.queueText,
      );
      expect(
        ChatSendPlanner.decide(
          content: 'hi',
          hasAttachments: false,
          isGroupMode: true,
          hasAgent: false,
          isProcessing: false,
        ),
        ChatSendDisposition.sendGroup,
      );
      expect(
        ChatSendPlanner.decide(
          content: 'hi',
          hasAttachments: false,
          isGroupMode: false,
          hasAgent: true,
          isProcessing: false,
        ),
        ChatSendDisposition.sendDm,
      );
    });
  });

  group('StreamingActionConfirmation', () {
    test('resolveHostMessageId prefers preferred then latest agent', () {
      final messages = [
        Message(
          id: 'u1',
          content: 'q',
          timestampMs: 1,
          from: MessageFrom(id: 'u', type: 'user', name: 'U'),
          type: MessageType.text,
        ),
        _agent('a1'),
        _agent('a2'),
      ];
      final map = {for (final m in messages) m.id: m};
      expect(
        StreamingActionConfirmation.resolveHostMessageId(
          preferredId: 'a1',
          messageIdMap: map,
          messages: messages,
        ),
        'a1',
      );
      expect(
        StreamingActionConfirmation.resolveHostMessageId(
          preferredId: 'missing',
          messageIdMap: map,
          messages: messages,
        ),
        'a2',
      );
    });

    test('attachToHost bumps approval_seq and replaces card', () {
      final host = _agent(
        'a1',
        content: 'partial',
        metadata: {
          'action_confirmation': {'confirmation_id': 'old'},
          'approval_seq': 1,
        },
      );
      expect(
        StreamingActionConfirmation.replacesPrior(
          existingMetadata: host.metadata,
          confirmationId: 'new',
        ),
        isTrue,
      );
      final updated = StreamingActionConfirmation.attachToHost(
        host: host,
        actionData: {'confirmation_id': 'new', 'prompt': 'ok?'},
        contentOverride: 'partial+',
      );
      expect(updated.content, 'partial+');
      expect(updated.metadata?['approval_seq'], 2);
      expect(
        (updated.metadata?['action_confirmation'] as Map)['confirmation_id'],
        'new',
      );
    });

    test('promptContent falls back and buildFallbackBubble sets metadata', () {
      expect(
        StreamingActionConfirmation.promptContent({}),
        StreamingActionConfirmation.fallbackPrompt,
      );
      final bubble = StreamingActionConfirmation.buildFallbackBubble(
        id: 'peer_approval_a_1',
        agentId: 'a',
        agentName: 'A',
        userId: 'u',
        userName: 'U',
        actionData: {'confirmation_id': 'c1', 'prompt': ' Allow? '},
        timestampMs: 9,
      );
      expect(bubble.content, 'Allow?');
      expect(bubble.timestampMs, 9);
      expect(
        (bubble.metadata?['action_confirmation'] as Map)['confirmation_id'],
        'c1',
      );
    });
  });

  group('InboundFileMessageParser', () {
    test('fileIdFromUrl extracts /files/{id}', () {
      expect(
        InboundFileMessageParser.fileIdFromUrl(
          'https://host/v1/files/abc-123?x=1',
        ),
        'abc-123',
      );
      expect(InboundFileMessageParser.fileIdFromUrl('/local/path'), isNull);
    });

    test('parse returns null without url or file_id', () {
      expect(InboundFileMessageParser.parse({}), isNull);
    });

    test('parse builds image draft from mime + file_id', () {
      final draft = InboundFileMessageParser.parse({
        'file_id': 'f1',
        'filename': 'pic.png',
        'mime_type': 'image/png',
        'size': 12,
        'thumbnail_base64': 'abc',
      });
      expect(draft, isNotNull);
      expect(draft!.isImage, isTrue);
      expect(draft.content, '[Image: pic.png]');
      expect(draft.metadata['file_id'], 'f1');
      expect(draft.metadata['thumbnail_base64'], 'abc');
      expect(draft.metadata['download_status'], 'pending');
    });

    test('needsLocalSizeProbe only for local paths with missing size', () {
      expect(
        InboundFileMessageParser.needsLocalSizeProbe('/tmp/a.bin', null),
        isTrue,
      );
      expect(
        InboundFileMessageParser.needsLocalSizeProbe('https://x/a', null),
        isFalse,
      );
      expect(
        InboundFileMessageParser.needsLocalSizeProbe('/tmp/a.bin', 10),
        isFalse,
      );
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';

void main() {
  group('LocalLLMHelpers store Scope Card folding', () {
    test('buildUserMessageContent folds store_uri attachment into Scope Card',
        () {
      final att = AttachmentData(
        fileName: 'note.txt',
        mimeType: 'text/plain',
        sizeBytes: 4,
        bytes: Uint8List.fromList([1, 2, 3, 4]),
        semanticType: 'document',
        extraMetadata: {
          'store_uri': 'store://files/0123456789abcdef/docs/note.txt',
        },
      );
      final msg = LocalLLMHelpers.buildUserMessageContent(
        'summarize this',
        [att],
        false,
      );
      final text = msg['content'] as String;
      // store:// refs fold into the Scope Card volatile section — no
      // per-message [implicit] block anymore.
      expect(text, contains('当前储物袋作用域'));
      expect(text, contains('shepaw store read'));
      expect(text, contains('store://files/0123456789abcdef/docs/note.txt'));
      expect(text, contains('summarize this'));
      expect(text, isNot(contains('[implicit]')));
    });

    test('enrichHistoryContent keeps fetch hint for store attachment', () {
      final m = Message(
        id: 'msg-1',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.file,
        content: '📎 File: note.txt',
        timestampMs: 0,
        metadata: {
          'store_uri': 'store://files/aaaaaaaaaaaaaaaa/note.txt',
          'name': 'note.txt',
        },
      );
      final enriched = LocalLLMHelpers.enrichHistoryContent(m, m.content);
      // History keeps only the message_id fetch hint; the store URI is
      // collected into the current-turn Scope Card instead.
      expect(enriched, isNot(contains('[implicit]')));
      expect(enriched, contains('message_id=msg-1'));
      expect(enriched, contains('chat message get'));
    });

    test('enrichHistoryContent text with store:// stays untouched', () {
      final m = Message(
        id: 'msg-2',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.text,
        content: 'read store://files/aaaaaaaaaaaaaaaa/a.txt please',
        timestampMs: 0,
      );
      final enriched = LocalLLMHelpers.enrichHistoryContent(m, m.content);
      expect(enriched, contains('store://files/aaaaaaaaaaaaaaaa/a.txt'));
      expect(enriched, isNot(contains('[implicit]')));
      expect(enriched, isNot(contains('chat message get')));
    });
  });

  group('LocalLLMHelpers.buildUserMessageContent audio', () {
    late AttachmentData audio;

    setUp(() {
      audio = AttachmentData(
        fileName: 'voice.m4a',
        mimeType: 'audio/mp4',
        sizeBytes: 4,
        bytes: Uint8List.fromList([0x00, 0x01, 0x02, 0x03]),
        semanticType: 'audio',
        extraMetadata: {'duration_ms': 2500},
      );
    });

    test('OpenAI path embeds input_audio bytes', () {
      final msg = LocalLLMHelpers.buildUserMessageContent(
        'Voice message (3s)',
        [audio],
        false,
      );
      final content = msg['content'];
      expect(content, isA<List>());
      final parts = content as List;
      expect(parts.any((p) => p['type'] == 'text'), isTrue);
      final audioPart = parts.cast<Map>().firstWhere(
            (p) => p['type'] == 'input_audio',
          );
      expect(audioPart['input_audio']['format'], 'm4a');
      expect(
        audioPart['input_audio']['data'],
        base64Encode([0x00, 0x01, 0x02, 0x03]),
      );
    });

    test('Claude path keeps audio as text description only', () {
      final msg = LocalLLMHelpers.buildUserMessageContent(
        'Voice message (3s)',
        [audio],
        true,
      );
      expect(msg['content'], isA<String>());
      final text = msg['content'] as String;
      expect(text, contains('[Audio: voice.m4a'));
      expect(text, contains('Voice message (3s)'));
      expect(text, isNot(contains('input_audio')));
    });
  });
}

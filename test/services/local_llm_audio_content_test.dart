import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';

void main() {
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

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_attachment_validator.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/pending_attachment.dart';
import 'package:shepaw/models/remote_agent.dart';

void main() {
  group('ChatAttachmentValidator', () {
    RemoteAgent localAgent({Map<String, dynamic>? metadata}) {
      final now = DateTime.now().millisecondsSinceEpoch;
      return RemoteAgent(
        id: 'local-1',
        name: 'Local',
        token: 't',
        endpoint: '',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        metadata: {'llm_provider': 'openai', ...?metadata},
        createdAt: now,
        updatedAt: now,
      );
    }

    RemoteAgent remoteAgent() {
      final now = DateTime.now().millisecondsSinceEpoch;
      return RemoteAgent(
        id: 'remote-1',
        name: 'Remote',
        token: 't',
        endpoint: 'https://example.com',
        protocol: ProtocolType.acp,
        connectionType: ConnectionType.http,
        metadata: const {},
        createdAt: now,
        updatedAt: now,
      );
    }

    PendingAttachment imagePending() => PendingAttachment(
          id: 'p1',
          file: File('/tmp/x.png'),
          fileName: 'x.png',
          fileSize: 10,
          type: PendingAttachmentType.image,
        );

    AttachmentData imageData() => AttachmentData(
          fileName: 'x.png',
          mimeType: 'image/png',
          sizeBytes: 10,
          bytes: Uint8List.fromList([1, 2, 3]),
          semanticType: 'image',
        );

    test('remote agents skip modality checks', () {
      expect(
        ChatAttachmentValidator.validatePendingForAgent(
          remoteAgent(),
          [imagePending()],
        ).ok,
        isTrue,
      );
      expect(
        ChatAttachmentValidator.validateDataForAgent(
          remoteAgent(),
          imageData(),
        ).ok,
        isTrue,
      );
    });

    test('local agent without image support rejects pending images', () {
      final result = ChatAttachmentValidator.validatePendingForAgent(
        localAgent(metadata: {
          'llm_api_base': 'http://localhost:11434/v1',
          'llm_model': 'gemma4',
        }),
        [imagePending()],
      );
      expect(result.ok, isFalse);
      expect(result.errorKey, 'chat_modalityNotSupported:image');
    });

    test('local agent without image support rejects image AttachmentData', () {
      final result = ChatAttachmentValidator.validateDataForAgent(
        localAgent(metadata: {
          'llm_api_base': 'http://localhost:11434/v1',
          'llm_model': 'gemma4',
        }),
        imageData(),
      );
      expect(result.ok, isFalse);
      expect(result.errorKey, startsWith('chat_modalityNotSupported:'));
    });
  });
}

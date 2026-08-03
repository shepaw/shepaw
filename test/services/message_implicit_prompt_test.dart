import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';

void main() {
  group('MessageImplicitPrompt', () {
    test('extractStoreUris from markdown and plain text', () {
      const text =
          'See [a.txt](store://files/0123456789abcdef/docs/a.txt) and '
          'store://artifacts/fedcba9876543210/t/b.md.';
      final uris = MessageImplicitPrompt.extractStoreUris(text);
      expect(
        uris,
        {
          'store://files/0123456789abcdef/docs/a.txt',
          'store://artifacts/fedcba9876543210/t/b.md',
        },
      );
    });

    test('forUserText null when no store uri', () {
      expect(MessageImplicitPrompt.forUserText('hello'), isNull);
    });

    test('forAttachments from extraMetadata store_uri', () {
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
      final hint = MessageImplicitPrompt.forAttachments([att]);
      expect(hint, isNotNull);
      expect(hint!, contains('[implicit]'));
      expect(hint, contains('[/implicit]'));
      expect(hint, contains('shepaw store read'));
      expect(hint, contains('store://files/0123456789abcdef/docs/note.txt'));
      expect(hint, contains('os.file.read'));
    });

    test('forCurrentTurn dedupes uri from text and attachment', () {
      const uri = 'store://files/0123456789abcdef/docs/note.txt';
      final att = AttachmentData(
        fileName: 'note.txt',
        mimeType: 'text/plain',
        sizeBytes: 1,
        bytes: Uint8List(0),
        semanticType: 'document',
        extraMetadata: {'store_uri': uri},
      );
      final hint = MessageImplicitPrompt.forCurrentTurn(
        text: 'Please read [$uri]($uri)',
        attachments: [att],
      );
      expect(hint, isNotNull);
      // URI listed once
      expect('URIs:'.allMatches(hint!).length, 1);
      expect(RegExp(RegExp.escape(uri)).allMatches(hint).length, 1);
    });

    test('forHistoryMessage from metadata and content', () {
      final m = Message(
        id: 'm1',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.file,
        content: '📎 File: x\n[x](store://files/aaaaaaaaaaaaaaaa/x.txt)',
        timestampMs: 0,
        metadata: {
          'store_uri': 'store://files/aaaaaaaaaaaaaaaa/x.txt',
          'name': 'x.txt',
        },
      );
      final hint = MessageImplicitPrompt.forHistoryMessage(m);
      expect(hint, contains('store://files/aaaaaaaaaaaaaaaa/x.txt'));
      expect(hint, contains('[implicit]'));
    });

    test('appendHint', () {
      expect(MessageImplicitPrompt.appendHint('a', null), 'a');
      expect(MessageImplicitPrompt.appendHint('', 'hint'), 'hint');
      expect(MessageImplicitPrompt.appendHint('a', 'hint'), 'a\nhint');
    });
  });
}

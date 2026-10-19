import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/services/messaging/message_implicit_prompt.dart';

void main() {
  group('MessageImplicitPrompt', () {
    test('extractStoreUris from markdown and plain text', () {
      const text =
          'See [a.txt](pouch://files/docs/a.txt) and '
          'pouch://artifacts/t/b.md.';
      final uris = MessageImplicitPrompt.extractStoreUris(text);
      expect(
        uris,
        {
          'pouch://files/docs/a.txt',
          'pouch://artifacts/t/b.md',
        },
      );
    });

    test('extractStoreUris ignores placeholders and doc templates', () {
      const text =
          'Talking about the pouch://xxx protocol, the '
          'pouch://<space>/<path> shape, a pathless pouch://files/ and '
          'pouch://files — but do read pouch://files/docs/a.txt please';
      final uris = MessageImplicitPrompt.extractStoreUris(text);
      expect(uris, {'pouch://files/docs/a.txt'});
    });

    test('renderStoreReadHint dedupes and sorts URIs', () {
      final hint = MessageImplicitPrompt.renderStoreReadHint({
        'pouch://files/docs/b.txt',
        'pouch://files/docs/a.txt',
      });
      expect(hint, isNotNull);
      expect(hint!, contains('[implicit]'));
      expect(hint, contains('[/implicit]'));
      expect(hint, contains('shepaw pouch read'));
      expect(hint, contains('not OS paths'));
      expect(
        hint.indexOf('pouch://files/docs/a.txt'),
        lessThan(hint.indexOf('pouch://files/docs/b.txt')),
      );
    });

    test('metadataForTurn stores the hint and structured URIs', () {
      const uri = 'pouch://files/docs/note.txt';
      final meta = MessageImplicitPrompt.metadataForTurn(text: 'see $uri');
      expect(meta, isNotNull);
      expect(meta![MessageImplicitPrompt.metaKey], contains('[implicit]'));
      expect(meta[MessageImplicitPrompt.urisMetaKey], [uri]);
      expect(
        MessageImplicitPrompt.fromMetadata(meta),
        meta[MessageImplicitPrompt.metaKey],
      );
    });

    test('metadataForTurn includes attachment URIs', () {
      final att = AttachmentData(
        fileName: 'note.txt',
        mimeType: 'text/plain',
        sizeBytes: 1,
        bytes: Uint8List(0),
        semanticType: 'document',
        extraMetadata: {
          'pouch_uri': 'pouch://files/docs/note.txt',
        },
      );
      final meta = MessageImplicitPrompt.metadataForTurn(
        text: 'please summarize',
        attachments: [att],
      );
      expect(meta![MessageImplicitPrompt.urisMetaKey],
          ['pouch://files/docs/note.txt']);
    });

    test('appendHint', () {
      expect(MessageImplicitPrompt.appendHint('a', null), 'a');
      expect(MessageImplicitPrompt.appendHint('', 'hint'), 'hint');
      expect(MessageImplicitPrompt.appendHint('a', 'hint'), 'a\nhint');
    });

    test('appendHint does not stack a second implicit block', () {
      final hint = MessageImplicitPrompt.renderStoreReadHint(
        {'pouch://files/docs/note.txt'},
      );
      final wire = MessageImplicitPrompt.appendHint('hi', hint);
      expect(MessageImplicitPrompt.appendHint(wire, hint), wire);
      expect(wire, contains('[implicit]'));
      expect(wire, contains('pouch://files/docs/note.txt'));
    });

    test('stripImplicitBlocks removes hint for display', () {
      final wire = MessageImplicitPrompt.appendHint(
        'please summarize',
        MessageImplicitPrompt.renderStoreReadHint(
          {'pouch://files/docs/note.txt'},
        ),
      );
      final display = MessageImplicitPrompt.stripImplicitBlocks(wire);
      expect(display, 'please summarize');
      expect(display, isNot(contains('[implicit]')));
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/inbound_file_message_parser.dart';
import 'package:shepaw/services/attachment_service.dart';

const _storeUri =
    'store://runtime/680a477ce6563798/she-builtin-agent-001/'
    'dm_she-builtin-agent-001_user_1787875105064/artifacts/general/tetris.html';

void main() {
  group('InboundFileMessageParser.parse', () {
    test('HTTP url keeps download_status pending', () {
      final draft = InboundFileMessageParser.parse({
        'url': 'https://host/files/abc123',
        'filename': 'report.pdf',
        'mime_type': 'application/pdf',
        'size': 1024,
      });
      expect(draft, isNotNull);
      expect(draft!.metadata['download_status'], 'pending');
      expect(draft.metadata['source_url'], 'https://host/files/abc123');
      expect(draft.metadata['store_uri'], isNull);
      expect(draft.metadata['size'], 1024);
    });

    test('store:// url is already available (completed + store_uri)', () {
      final draft = InboundFileMessageParser.parse({
        'url': _storeUri,
        'filename': 'tetris.html',
        'mime_type': 'text/html',
      });
      expect(draft, isNotNull);
      expect(draft!.metadata['download_status'], 'completed');
      expect(draft.metadata['source_url'], _storeUri);
      expect(draft.metadata['store_uri'], _storeUri);
      // size not provided → 0, bubble resolves lazily from the store.
      expect(draft.metadata['size'], 0);
      expect(draft.metadata['file_id'], isNull);
    });

    test('store:// url keeps explicit file_id but stays completed', () {
      final draft = InboundFileMessageParser.parse({
        'url': _storeUri,
        'file_id': 'abc123',
        'filename': 'tetris.html',
        'mime_type': 'text/html',
      });
      expect(draft, isNotNull);
      expect(draft!.metadata['download_status'], 'completed');
      expect(draft.metadata['store_uri'], _storeUri);
      expect(draft.metadata['file_id'], 'abc123');
    });

    test('file_id only (no url) stays pending', () {
      final draft = InboundFileMessageParser.parse({
        'file_id': 'abc123',
        'filename': 'report.pdf',
        'mime_type': 'application/pdf',
      });
      expect(draft, isNotNull);
      expect(draft!.metadata['download_status'], 'pending');
      expect(draft.metadata['store_uri'], isNull);
      expect(draft.metadata['file_id'], 'abc123');
    });

    test('fileIdFromUrl still extracts /files/{id} from http url', () {
      expect(
        InboundFileMessageParser.fileIdFromUrl(
          'http://host:8080/files/xyz789',
        ),
        'xyz789',
      );
      expect(
        InboundFileMessageParser.fileIdFromUrl(
          'https://host/files/xyz789',
        ),
        'xyz789',
      );
      expect(
        InboundFileMessageParser.fileIdFromUrl(_storeUri),
        isNull,
      );
    });
  });

  group('AttachmentService.storeUriOf', () {
    test('explicit store_uri wins', () {
      expect(
        AttachmentService.storeUriOf({'store_uri': _storeUri}),
        _storeUri,
      );
    });

    test('store:// source_url fallback for legacy messages', () {
      expect(
        AttachmentService.storeUriOf({'source_url': _storeUri}),
        _storeUri,
      );
    });

    test('http source_url without store_uri → null', () {
      expect(
        AttachmentService.storeUriOf({
          'source_url': 'https://host/files/abc123',
        }),
        isNull,
      );
    });

    test('explicit store_uri preferred over conflicting source_url', () {
      expect(
        AttachmentService.storeUriOf({
          'store_uri': _storeUri,
          'source_url': 'https://host/files/abc123',
        }),
        _storeUri,
      );
    });

    test('null / empty metadata → null', () {
      expect(AttachmentService.storeUriOf(null), isNull);
      expect(AttachmentService.storeUriOf(<String, dynamic>{}), isNull);
    });
  });
}

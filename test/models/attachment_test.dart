import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/attachment_data.dart';
import 'package:shepaw/models/pending_attachment.dart';

void main() {
  group('AttachmentData Tests', () {
    late AttachmentData imageAttachment;
    late AttachmentData fileAttachment;

    setUp(() {
      imageAttachment = AttachmentData(
        fileName: 'photo.jpg',
        mimeType: 'image/jpeg',
        sizeBytes: 2 * 1024 * 1024, // 2 MB
        bytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]), // JPEG header
        semanticType: 'image',
      );

      fileAttachment = AttachmentData(
        fileName: 'document.pdf',
        mimeType: 'application/pdf',
        sizeBytes: 512,
        bytes: Uint8List.fromList([0x25, 0x50, 0x44, 0x46]),
        semanticType: 'document',
      );
    });

    test('should store fields correctly', () {
      expect(imageAttachment.fileName, 'photo.jpg');
      expect(imageAttachment.mimeType, 'image/jpeg');
      expect(imageAttachment.sizeBytes, 2 * 1024 * 1024);
      expect(imageAttachment.semanticType, 'image');
      expect(imageAttachment.extraMetadata, isNull);
    });

    test('isImage should return true for image semantic type', () {
      expect(imageAttachment.isImage, true);
      expect(fileAttachment.isImage, false);
    });

    test('base64Data should encode bytes correctly', () {
      final expected = base64Encode([0xFF, 0xD8, 0xFF, 0xE0]);
      expect(imageAttachment.base64Data, expected);
    });

    test('exceedsSizeLimit should check 20MB limit', () {
      expect(imageAttachment.exceedsSizeLimit, false);

      final largeAttachment = AttachmentData(
        fileName: 'big.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: 21 * 1024 * 1024, // 21 MB
        bytes: Uint8List(0),
        semanticType: 'file',
      );
      expect(largeAttachment.exceedsSizeLimit, true);

      final exactLimit = AttachmentData(
        fileName: 'exact.bin',
        mimeType: 'application/octet-stream',
        sizeBytes: 20 * 1024 * 1024, // exactly 20 MB
        bytes: Uint8List(0),
        semanticType: 'file',
      );
      expect(exactLimit.exceedsSizeLimit, false);
    });

    group('textDescription', () {
      test('should format image description', () {
        expect(imageAttachment.textDescription, '[Image: photo.jpg (2.0 MB)]');
      });

      test('should format document description', () {
        expect(fileAttachment.textDescription, '[Document: document.pdf (512 B)]');
      });

      test('should format audio description', () {
        final audio = AttachmentData(
          fileName: 'voice.mp3',
          mimeType: 'audio/mp3',
          sizeBytes: 100 * 1024,
          bytes: Uint8List(0),
          semanticType: 'audio',
        );
        expect(audio.textDescription, '[Audio: voice.mp3 (100.0 KB)]');
      });

      test('should format video description', () {
        final video = AttachmentData(
          fileName: 'clip.mp4',
          mimeType: 'video/mp4',
          sizeBytes: 5 * 1024 * 1024,
          bytes: Uint8List(0),
          semanticType: 'video',
        );
        expect(video.textDescription, '[Video: clip.mp4 (5.0 MB)]');
      });

      test('should default to File for unknown semantic type', () {
        final unknown = AttachmentData(
          fileName: 'data.bin',
          mimeType: 'application/octet-stream',
          sizeBytes: 256,
          bytes: Uint8List(0),
          semanticType: 'unknown',
        );
        expect(unknown.textDescription, '[File: data.bin (256 B)]');
      });

      test('should include duration from extraMetadata', () {
        final audioWithDuration = AttachmentData(
          fileName: 'recording.m4a',
          mimeType: 'audio/m4a',
          sizeBytes: 50 * 1024,
          bytes: Uint8List(0),
          semanticType: 'audio',
          extraMetadata: {'duration_ms': 15000},
        );
        expect(audioWithDuration.textDescription,
            '[Audio: recording.m4a (50.0 KB, 15s)]');
      });

      test('should not include duration when zero', () {
        final audioNoDuration = AttachmentData(
          fileName: 'clip.mp3',
          mimeType: 'audio/mp3',
          sizeBytes: 1024,
          bytes: Uint8List(0),
          semanticType: 'audio',
          extraMetadata: {'duration_ms': 0},
        );
        expect(audioNoDuration.textDescription, '[Audio: clip.mp3 (1.0 KB)]');
      });
    });

    group('toJson', () {
      test('should produce correct JSON', () {
        final json = imageAttachment.toJson();

        expect(json['file_name'], 'photo.jpg');
        expect(json['mime_type'], 'image/jpeg');
        expect(json['size'], 2 * 1024 * 1024);
        expect(json['data'], imageAttachment.base64Data);
        expect(json['type'], 'image');
        expect(json.containsKey('extra'), false);
      });

      test('should include extra metadata when present', () {
        final withExtra = AttachmentData(
          fileName: 'a.mp3',
          mimeType: 'audio/mp3',
          sizeBytes: 100,
          bytes: Uint8List(0),
          semanticType: 'audio',
          extraMetadata: {'duration_ms': 5000},
        );

        final json = withExtra.toJson();
        expect(json['extra'], {'duration_ms': 5000});
      });
    });
  });

  group('PendingAttachment Tests', () {
    group('inferType', () {
      test('should detect image types', () {
        final imageExtensions = [
          'photo.jpg', 'pic.jpeg', 'image.png',
          'anim.gif', 'bitmap.bmp', 'modern.webp',
        ];

        for (final path in imageExtensions) {
          expect(
            PendingAttachment.inferType(path),
            PendingAttachmentType.image,
            reason: 'Expected "$path" to be detected as image',
          );
        }
      });

      test('should detect image types case-insensitively', () {
        expect(PendingAttachment.inferType('photo.JPG'), PendingAttachmentType.image);
        expect(PendingAttachment.inferType('pic.PNG'), PendingAttachmentType.image);
      });

      test('should detect non-image types as file', () {
        final fileExtensions = [
          'doc.pdf', 'sheet.xlsx', 'code.dart',
          'archive.zip', 'video.mp4', 'audio.mp3',
          'data.json', 'readme.txt',
        ];

        for (final path in fileExtensions) {
          expect(
            PendingAttachment.inferType(path),
            PendingAttachmentType.file,
            reason: 'Expected "$path" to be detected as file',
          );
        }
      });
    });

    group('formatFileSize', () {
      test('should format bytes', () {
        expect(PendingAttachment.formatFileSize(0), '0 B');
        expect(PendingAttachment.formatFileSize(100), '100 B');
        expect(PendingAttachment.formatFileSize(1023), '1023 B');
      });

      test('should format kilobytes', () {
        expect(PendingAttachment.formatFileSize(1024), '1.0 KB');
        expect(PendingAttachment.formatFileSize(1536), '1.5 KB');
        expect(PendingAttachment.formatFileSize(10240), '10.0 KB');
      });

      test('should format megabytes', () {
        expect(PendingAttachment.formatFileSize(1024 * 1024), '1.0 MB');
        expect(PendingAttachment.formatFileSize(5 * 1024 * 1024), '5.0 MB');
      });

      test('should format gigabytes', () {
        expect(PendingAttachment.formatFileSize(1024 * 1024 * 1024), '1.0 GB');
        expect(PendingAttachment.formatFileSize(2 * 1024 * 1024 * 1024), '2.0 GB');
      });
    });

    group('PendingAttachmentType enum', () {
      test('should have image and file values', () {
        expect(PendingAttachmentType.values.length, 2);
        expect(PendingAttachmentType.values, contains(PendingAttachmentType.image));
        expect(PendingAttachmentType.values, contains(PendingAttachmentType.file));
      });
    });
  });
}

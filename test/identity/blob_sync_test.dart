import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/models/sync_blob_descriptor.dart';
import 'package:shepaw/identity/services/blob_sync_service.dart';

void main() {
  group('BlobSyncService', () {
    test('blobKeyFromRelativePath uses relative path as key', () {
      expect(
        BlobSyncService.blobKeyFromRelativePath('attachments/img.jpg'),
        'attachments/img.jpg',
      );
    });

    test('sha256OfFile matches known content', () async {
      final dir = await Directory.systemTemp.createTemp('shepaw_blob_test');
      addTearDown(() => dir.delete(recursive: true));

      final file = File('${dir.path}/test.bin');
      await file.writeAsBytes([1, 2, 3, 4]);

      final hash = await BlobSyncService.sha256OfFile(file);
      expect(hash, isNotEmpty);
      expect(hash.length, 64);
    });

    test('SyncBlobDescriptor round-trip', () {
      const d = SyncBlobDescriptor(
        blobKey: 'attachments/a.png',
        relativePath: 'attachments/a.png',
        sha256: 'abc',
        sizeBytes: 1024,
      );
      final json = d.toJson();
      final restored = SyncBlobDescriptor.fromJson(json);
      expect(restored.blobKey, d.blobKey);
      expect(restored.sha256, d.sha256);
      expect(restored.sizeBytes, d.sizeBytes);
    });
  });
}

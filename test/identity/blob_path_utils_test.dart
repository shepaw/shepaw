import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/blob_path_utils.dart';

void main() {
  group('BlobPathUtils', () {
    test('accepts normal relative paths', () {
      expect(BlobPathUtils.isValidRelativeStoragePath('attachments/a.png'), isTrue);
      expect(BlobPathUtils.isValidRelativeStoragePath('images/sub/file.jpg'), isTrue);
    });

    test('rejects traversal and absolute paths', () {
      expect(BlobPathUtils.isValidRelativeStoragePath('../etc/passwd'), isFalse);
      expect(BlobPathUtils.isValidRelativeStoragePath('attachments/../../x'), isFalse);
      expect(BlobPathUtils.isValidRelativeStoragePath('/etc/passwd'), isFalse);
      expect(BlobPathUtils.isValidRelativeStoragePath(r'C:\windows\system32'), isFalse);
      expect(BlobPathUtils.isValidRelativeStoragePath(''), isFalse);
    });

    test('resolveUnderRoot blocks escape', () {
      const root = '/tmp/account/files';
      expect(
        BlobPathUtils.resolveUnderRoot(root, 'attachments/a.png'),
        '/tmp/account/files/attachments/a.png',
      );
      expect(BlobPathUtils.resolveUnderRoot(root, '../outside'), isNull);
    });
  });
}

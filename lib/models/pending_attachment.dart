import 'dart:io';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'package:path/path.dart' as path;

enum PendingAttachmentType { image, file }

class PendingAttachment {
  final String id;
  final File file;
  final String fileName;
  final int fileSize;
  final PendingAttachmentType type;
  final Uint8List? thumbnailBytes;
  final bool isFromClipboard;

  PendingAttachment({
    required this.id,
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.type,
    this.thumbnailBytes,
    this.isFromClipboard = false,
  });

  static const _imageExtensions = {
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp',
  };

  static PendingAttachmentType inferType(String filePath) {
    final ext = path.extension(filePath).toLowerCase();
    return _imageExtensions.contains(ext)
        ? PendingAttachmentType.image
        : PendingAttachmentType.file;
  }

  static Future<PendingAttachment> fromFile(
    File file, {
    bool isFromClipboard = false,
  }) async {
    final fileName = path.basename(file.path);
    final fileSize = await file.length();
    final type = inferType(file.path);

    Uint8List? thumbnail;
    if (type == PendingAttachmentType.image) {
      try {
        thumbnail = await file.readAsBytes();
      } catch (_) {}
    }

    return PendingAttachment(
      id: const Uuid().v4(),
      file: file,
      fileName: fileName,
      fileSize: fileSize,
      type: type,
      thumbnailBytes: thumbnail,
      isFromClipboard: isFromClipboard,
    );
  }

  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

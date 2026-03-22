import 'dart:convert';
import 'dart:typed_data';

/// Lightweight data class encapsulating an attachment to be sent to an agent.
class AttachmentData {
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List bytes;

  /// One of: 'image', 'audio', 'video', 'document', 'file'
  final String semanticType;
  final Map<String, dynamic>? extraMetadata;

  AttachmentData({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    required this.semanticType,
    this.extraMetadata,
  });

  String get base64Data => base64Encode(bytes);

  bool get isImage => semanticType == 'image';

  bool get exceedsSizeLimit => sizeBytes > 20 * 1024 * 1024; // 20 MB

  /// Human-readable text description, e.g. "[Image: photo.jpg (2.1MB)]"
  String get textDescription {
    final formattedSize = _formatSize(sizeBytes);
    final prefix = switch (semanticType) {
      'image' => 'Image',
      'audio' => 'Audio',
      'video' => 'Video',
      'document' => 'Document',
      _ => 'File',
    };

    final extra = StringBuffer();
    if (extraMetadata != null) {
      final durationMs = extraMetadata!['duration_ms'];
      if (durationMs is int && durationMs > 0) {
        extra.write(', ${(durationMs / 1000).round()}s');
      }
    }

    return '[$prefix: $fileName ($formattedSize$extra)]';
  }

  /// Serialize to the JSON map sent over ACP protocol.
  Map<String, dynamic> toJson() => {
        'file_name': fileName,
        'mime_type': mimeType,
        'size': sizeBytes,
        'data': base64Data,
        'type': semanticType,
        if (extraMetadata != null) 'extra': extraMetadata,
      };

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

import '../models/message.dart';

/// Parsed inbound agent file payload ready for DB persistence.
class InboundFileDraft {
  final String? url;
  final String? fileId;
  final String filename;
  final String mimeType;
  final int size;
  final String? thumbnailBase64;
  final bool isImage;
  final Map<String, dynamic> metadata;
  final String content;
  final MessageType messageType;

  const InboundFileDraft({
    required this.url,
    required this.fileId,
    required this.filename,
    required this.mimeType,
    required this.size,
    required this.thumbnailBase64,
    required this.isImage,
    required this.metadata,
    required this.content,
    required this.messageType,
  });
}

/// Pure parsing for agent `onFileMessage` payloads.
class InboundFileMessageParser {
  InboundFileMessageParser._();

  /// Extract `/files/{id}` segment from a URL, if present.
  static String? fileIdFromUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      if (uri.hasScheme &&
          uri.pathSegments.length >= 2 &&
          uri.pathSegments[uri.pathSegments.length - 2] == 'files') {
        return uri.pathSegments.last;
      }
    } catch (_) {}
    return null;
  }

  /// Returns null when neither url nor file_id is usable.
  static InboundFileDraft? parse(
    Map<String, dynamic> fileData, {
    int? resolvedSize,
  }) {
    final url = fileData['url'] as String?;
    final filename = fileData['filename'] as String?;
    final fileMimeType = fileData['mime_type'] as String?;
    var size = resolvedSize ?? (fileData['size'] as num?)?.toInt();
    final thumbnailBase64 = fileData['thumbnail_base64'] as String?;

    var fileId = fileData['file_id'] as String?;
    if (fileId == null || fileId.isEmpty) {
      fileId = fileIdFromUrl(url);
    }

    if ((url == null || url.isEmpty) && (fileId == null || fileId.isEmpty)) {
      return null;
    }

    final mimeType = fileMimeType ?? 'application/octet-stream';
    final isImage = mimeType.startsWith('image/');
    final safeName = filename ?? (isImage ? 'image' : 'file');
    final metadata = <String, dynamic>{
      'download_status': 'pending',
      'name': filename ?? 'file',
      'type': mimeType,
      'size': size ?? 0,
    };
    if (url != null && url.isNotEmpty) metadata['source_url'] = url;
    if (thumbnailBase64 != null && thumbnailBase64.isNotEmpty) {
      metadata['thumbnail_base64'] = thumbnailBase64;
    }
    if (fileId != null) metadata['file_id'] = fileId;

    return InboundFileDraft(
      url: url,
      fileId: fileId,
      filename: safeName,
      mimeType: mimeType,
      size: size ?? 0,
      thumbnailBase64: thumbnailBase64,
      isImage: isImage,
      metadata: metadata,
      content: isImage ? '[Image: $safeName]' : '[File: $safeName]',
      messageType: isImage ? MessageType.image : MessageType.file,
    );
  }

  /// True when [url] is a non-http local path that may need a filesystem size probe.
  static bool needsLocalSizeProbe(String? url, int? size) {
    if (size != null && size > 0) return false;
    if (url == null || url.isEmpty) return false;
    return !url.startsWith('http');
  }
}

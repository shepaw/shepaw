import 'dart:convert';
import 'dart:typed_data';

/// Lightweight data class encapsulating an attachment to be sent to an agent.
class AttachmentData {
  /// ACP / general / peer file-push size ceiling (decoded bytes).
  static const int maxSizeBytes = 20 * 1024 * 1024; // 20 MB

  /// Peer control-frame chunk size (decoded bytes per agent_file_chunk).
  /// Keep well under typical relay / WS practical limits (avatar budget ~256KiB
  /// raw; base64 + JSON + Noise expand ~1.4x).
  static const int peerChunkBytes = 48 * 1024; // 48 KiB

  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final Uint8List bytes;

  /// One of: 'image', 'audio', 'video', 'document', 'file'
  final String semanticType;
  final Map<String, dynamic>? extraMetadata;

  /// Peer wire `file_id` after a successful push (optional).
  final String? fileId;

  AttachmentData({
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.bytes,
    required this.semanticType,
    this.extraMetadata,
    this.fileId,
  });

  /// Deserialize from ACP (with `data`) or peer ref (with `file_id`, no bytes).
  factory AttachmentData.fromJson(Map<String, dynamic> json) {
    final data = json['data'] as String? ?? '';
    final bytes = data.isEmpty ? Uint8List(0) : base64Decode(data);
    final reportedSize = json['size'] as int?;
    return AttachmentData(
      fileName: json['file_name'] as String? ?? 'file',
      mimeType: json['mime_type'] as String? ?? 'application/octet-stream',
      sizeBytes: reportedSize ?? bytes.length,
      bytes: bytes,
      semanticType: json['type'] as String? ?? 'file',
      extraMetadata: json['extra'] as Map<String, dynamic>?,
      fileId: json['file_id'] as String?,
    );
  }

  /// Parse a wire `attachments` list; returns null when empty / absent.
  /// Invalid entries are skipped.
  static List<AttachmentData>? listFromJson(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <AttachmentData>[];
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        out.add(AttachmentData.fromJson(Map<String, dynamic>.from(item)));
      } catch (_) {
        // Skip malformed entries.
      }
    }
    return out.isEmpty ? null : out;
  }

  /// Peer `agent_chat` attachment refs (no base64 payload).
  static List<Map<String, dynamic>>? peerRefListFromJson(dynamic raw) {
    if (raw is! List || raw.isEmpty) return null;
    final out = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final fileId = map['file_id'] as String?;
      if (fileId == null || fileId.isEmpty) continue;
      out.add(map);
    }
    return out.isEmpty ? null : out;
  }

  String get base64Data => base64Encode(bytes);

  bool get isImage => semanticType == 'image';

  bool get isAudio => semanticType == 'audio';

  /// Format string for OpenAI-compatible `input_audio.format`.
  ///
  /// OpenAI officially documents wav/mp3/flac/opus/pcm16; m4a is kept for
  /// Omni-style models that accept AAC-in-MP4. Callers may degrade on 4xx.
  String get audioFormat {
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    switch (ext) {
      case 'wav':
        return 'wav';
      case 'mp3':
        return 'mp3';
      case 'flac':
        return 'flac';
      case 'ogg':
      case 'opus':
        return 'opus';
      case 'm4a':
      case 'aac':
        return 'm4a';
      default:
        break;
    }
    final mime = mimeType.toLowerCase();
    if (mime.contains('wav')) return 'wav';
    if (mime.contains('mpeg') || mime.contains('mp3')) return 'mp3';
    if (mime.contains('flac')) return 'flac';
    if (mime.contains('ogg') || mime.contains('opus')) return 'opus';
    if (mime.contains('mp4') || mime.contains('m4a') || mime.contains('aac')) {
      return 'm4a';
    }
    return 'wav';
  }

  bool get exceedsSizeLimit => sizeBytes > maxSizeBytes;

  bool get hasBytes => bytes.isNotEmpty;

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

  /// Serialize to the JSON map sent over ACP protocol (includes base64).
  Map<String, dynamic> toJson() => {
        'file_name': fileName,
        'mime_type': mimeType,
        'size': sizeBytes,
        'data': base64Data,
        'type': semanticType,
        if (extraMetadata != null) 'extra': extraMetadata,
        if (fileId != null) 'file_id': fileId,
      };

  /// Peer `agent_chat` attachment reference (no `data`).
  Map<String, dynamic> toPeerRefJson(String fileId) => {
        'file_id': fileId,
        'file_name': fileName,
        'mime_type': mimeType,
        'size': sizeBytes,
        'type': semanticType,
        if (extraMetadata != null) 'extra': extraMetadata,
      };

  AttachmentData copyWith({
    String? fileName,
    String? mimeType,
    int? sizeBytes,
    Uint8List? bytes,
    String? semanticType,
    Map<String, dynamic>? extraMetadata,
    String? fileId,
  }) {
    return AttachmentData(
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      bytes: bytes ?? this.bytes,
      semanticType: semanticType ?? this.semanticType,
      extraMetadata: extraMetadata ?? this.extraMetadata,
      fileId: fileId ?? this.fileId,
    );
  }

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Sanitize a file name for safe path segments.
  static String safeFileName(String name) {
    final cleaned = name.replaceAll(RegExp(r'[^\w.\-]+'), '_');
    if (cleaned.isEmpty) return 'file';
    return cleaned.length > 80 ? cleaned.substring(0, 80) : cleaned;
  }
}

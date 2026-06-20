/// 同步附件 blob 描述（以相对存储路径为主键）。
class SyncBlobDescriptor {
  final String blobKey;
  final String relativePath;
  final String sha256;
  final int sizeBytes;
  final String? mimeType;

  const SyncBlobDescriptor({
    required this.blobKey,
    required this.relativePath,
    required this.sha256,
    required this.sizeBytes,
    this.mimeType,
  });

  Map<String, dynamic> toJson() => {
        'blob_key': blobKey,
        'relative_path': relativePath,
        'sha256': sha256,
        'size_bytes': sizeBytes,
        if (mimeType != null) 'mime_type': mimeType,
      };

  factory SyncBlobDescriptor.fromJson(Map<String, dynamic> json) => SyncBlobDescriptor(
        blobKey: json['blob_key'] as String,
        relativePath: json['relative_path'] as String? ?? json['blob_key'] as String,
        sha256: json['sha256'] as String? ?? '',
        sizeBytes: json['size_bytes'] as int? ?? 0,
        mimeType: json['mime_type'] as String?,
      );
}

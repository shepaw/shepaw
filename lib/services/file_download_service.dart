import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'local_file_storage_service.dart';
import 'logger_service.dart';

/// Result of a file download operation
class FileDownloadResult {
  /// Relative path within local storage
  final String relativePath;

  /// Original file name
  final String fileName;

  /// File size in bytes
  final int fileSize;

  /// MIME type of the file
  final String mimeType;

  /// Whether the file is an image
  final bool isImage;

  FileDownloadResult({
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.isImage,
  });
}

/// Service for downloading files from URLs and saving them locally
class FileDownloadService {
  final LocalFileStorageService _storageService;
  late final LoggerService _logger;

  FileDownloadService([LocalFileStorageService? storageService])
      : _storageService = storageService ?? LocalFileStorageService() {
    _logger = LoggerService();
  }

  /// Check if a MIME type represents an image
  static bool isImageMimeType(String mimeType) {
    return mimeType.startsWith('image/');
  }

  /// Download a file from [url] and save it locally.
  ///
  /// [url] may be an HTTP/HTTPS URL or an absolute local file path.
  /// Returns a [FileDownloadResult] with the local path and metadata.
  Future<FileDownloadResult> downloadAndSave(
    String url, {
    String? fileName,
    String? mimeType,
    int? expectedSize,
    void Function(int received, int? total)? onProgress,
  }) async {
    _logger.info(
      'downloadAndSave() called with url=$url',
      tag: 'FileDownloadService',
    );

    // Handle local file paths directly without HTTP
    final uri = Uri.parse(url);
    
    _logger.info(
      'URL parsed - scheme=${uri.scheme}, hasScheme=${uri.hasScheme}, host=${uri.host}',
      tag: 'FileDownloadService',
    );

    if (!uri.hasScheme || uri.scheme == 'file' || url.startsWith('/')) {
      _logger.info('Copying local file: $url', tag: 'FileDownloadService');
      return _copyLocalFile(url, fileName: fileName, mimeType: mimeType, onProgress: onProgress);
    }

    _logger.info(
      'Downloading from URL: $url (scheme=${uri.scheme})',
      tag: 'FileDownloadService',
    );

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      final streamedResponse = await client.send(request);

      _logger.info(
        'HTTP response received: status=${streamedResponse.statusCode}, '
        'contentLength=${streamedResponse.contentLength}',
        tag: 'FileDownloadService',
      );

      if (streamedResponse.statusCode != 200) {
        throw Exception(
          'Download failed with status ${streamedResponse.statusCode}',
        );
      }

      // Determine MIME type from response or parameter
      final responseMime = streamedResponse.headers['content-type']
              ?.split(';')
              .first
              .trim() ??
          'application/octet-stream';
      final effectiveMime = mimeType ?? responseMime;

      // Determine file name
      final effectiveFileName = fileName ?? _fileNameFromUrl(url, effectiveMime);

      // Determine resource type based on MIME
      final ResourceType resourceType;
      if (effectiveMime.startsWith('image/')) {
        resourceType = ResourceType.images;
      } else if (effectiveMime.startsWith('audio/')) {
        resourceType = ResourceType.audio;
      } else {
        resourceType = ResourceType.documents;
      }

      // Download to a temp file using streaming
      final tempDir = await _storageService.getStorageDirectory();
      final tempFile = File(
        path.join(tempDir.path, 'temp', 'download_${DateTime.now().millisecondsSinceEpoch}'),
      );
      await tempFile.parent.create(recursive: true);

      final total = streamedResponse.contentLength ?? expectedSize;
      int received = 0;
      final sink = tempFile.openWrite();

      try {
        await for (final chunk in streamedResponse.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }

      // Save to permanent storage using LocalFileStorageService
      final relativePath = await _storageService.saveFile(
        tempFile,
        type: resourceType,
        customFileName: effectiveFileName,
      );

      // Clean up temp file
      try {
        await tempFile.delete();
      } catch (_) {}

      final fileSize = received;

      _logger.info(
        'Download completed successfully: $effectiveFileName ($fileSize bytes)',
        tag: 'FileDownloadService',
      );

      return FileDownloadResult(
        relativePath: relativePath,
        fileName: effectiveFileName,
        fileSize: fileSize,
        mimeType: effectiveMime,
        isImage: isImageMimeType(effectiveMime),
      );
    } on SocketException catch (e) {
      _logger.error('Network error during download', tag: 'FileDownloadService', error: e);
      rethrow;
    } on TimeoutException catch (e) {
      _logger.error('Download timeout', tag: 'FileDownloadService', error: e);
      rethrow;
    } catch (e, stack) {
      _logger.error(
        'Unexpected error during download',
        tag: 'FileDownloadService',
        error: e,
        stackTrace: stack,
      );
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Derive a file name from a URL, falling back to a UUID-based name.
  String _fileNameFromUrl(String url, String mimeType) {
    try {
      final uri = Uri.parse(url);
      final segments = uri.pathSegments;
      if (segments.isNotEmpty) {
        final last = segments.last;
        if (last.contains('.') && last.length <= 255) {
          return last;
        }
      }
    } catch (_) {}

    // Fallback: generate name from timestamp + extension
    final ext = _extensionFromMime(mimeType);
    return 'file_${DateTime.now().millisecondsSinceEpoch}$ext';
  }

  /// Map common MIME types to file extensions.
  String _extensionFromMime(String mimeType) {
    const mimeToExt = {
      'image/jpeg': '.jpg',
      'image/png': '.png',
      'image/gif': '.gif',
      'image/webp': '.webp',
      'application/pdf': '.pdf',
      'application/zip': '.zip',
      'text/plain': '.txt',
      'text/html': '.html',
      'audio/mpeg': '.mp3',
      'audio/wav': '.wav',
      'audio/ogg': '.ogg',
      'video/mp4': '.mp4',
    };
    return mimeToExt[mimeType] ?? '';
  }

  /// Copy a local file into managed storage.
  Future<FileDownloadResult> _copyLocalFile(
    String filePath, {
    String? fileName,
    String? mimeType,
    void Function(int received, int? total)? onProgress,
  }) async {
    final source = File(filePath);
    if (!await source.exists()) {
      throw Exception('Local file not found: $filePath');
    }

    final effectiveMime = mimeType ?? 'application/octet-stream';
    final effectiveFileName = fileName ?? path.basename(filePath);

    final ResourceType resourceType;
    if (effectiveMime.startsWith('image/')) {
      resourceType = ResourceType.images;
    } else if (effectiveMime.startsWith('audio/')) {
      resourceType = ResourceType.audio;
    } else {
      resourceType = ResourceType.documents;
    }

    final fileSize = await source.length();
    onProgress?.call(fileSize, fileSize);

    final relativePath = await _storageService.saveFile(
      source,
      type: resourceType,
      customFileName: effectiveFileName,
    );

    return FileDownloadResult(
      relativePath: relativePath,
      fileName: effectiveFileName,
      fileSize: fileSize,
      mimeType: effectiveMime,
      isImage: isImageMimeType(effectiveMime),
    );
  }
}

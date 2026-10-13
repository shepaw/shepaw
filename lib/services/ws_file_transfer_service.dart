/// WebSocket Binary File Transfer Service
///
/// Coordinates file downloads over WebSocket binary frames, providing an
/// alternative to HTTP downloads that works when agents are behind NAT/firewall.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as path;
import '../models/acp_protocol.dart';
import 'local_file_storage_service.dart';
import 'logger_service.dart';

/// Result of a WebSocket file download.
class WsFileDownloadResult {
  final String relativePath;
  final String fileName;
  final int fileSize;
  final String mimeType;
  final bool isImage;

  WsFileDownloadResult({
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.isImage,
  });
}

/// Tracks a single in-progress file transfer.
class _ActiveDownload {
  final String fileId;
  String? filename;
  String? mimeType;
  int expectedSize = 0;
  int receivedBytes = 0;
  final IOSink fileSink;
  final File tempFile;
  final Completer<WsFileDownloadResult> completer;
  final void Function(int received, int? total)? onProgress;

  _ActiveDownload({
    required this.fileId,
    required this.fileSink,
    required this.tempFile,
    required this.completer,
    this.onProgress,
  });
}

/// Singleton service that coordinates file downloads over WebSocket.
class WsFileTransferService {
  static final WsFileTransferService _instance =
      WsFileTransferService._internal();
  factory WsFileTransferService() => _instance;
  WsFileTransferService._internal();

  final LocalFileStorageService _storageService = LocalFileStorageService();
  final Map<String, _ActiveDownload> _activeDownloads = {};



  void _handleChunk(String fileId, Uint8List chunk) {
    final download = _activeDownloads[fileId];
    if (download == null) return;

    download.fileSink.add(chunk);
    download.receivedBytes += chunk.length;
    download.onProgress?.call(
      download.receivedBytes,
      download.expectedSize > 0 ? download.expectedSize : null,
    );
  }

  Future<void> _handleTransferComplete(String fileId, int totalBytes) async {
    final download = _activeDownloads.remove(fileId);
    if (download == null) return;

    try {
      await download.fileSink.flush();
      await download.fileSink.close();

      final filename = download.filename ?? 'file_$fileId';
      final mimeType = download.mimeType ?? 'application/octet-stream';
      final isImage = mimeType.startsWith('image/');

      // Save to permanent storage
      final resourceType =
          isImage ? ResourceType.images : ResourceType.documents;
      final relativePath = await _storageService.saveFile(
        download.tempFile,
        type: resourceType,
        customFileName: filename,
      );

      // Clean up temp file
      if (await download.tempFile.exists()) {
        await download.tempFile.delete();
      }

      LoggerService().info('Completed: $filename ($totalBytes bytes)', tag: 'WSFileTransfer');

      download.completer.complete(WsFileDownloadResult(
        relativePath: relativePath,
        fileName: filename,
        fileSize: totalBytes,
        mimeType: mimeType,
        isImage: isImage,
      ));
    } catch (e) {
      download.completer.completeError(e);
    }
  }

  void _handleTransferError(String fileId, String error) {
    final download = _activeDownloads.remove(fileId);
    if (download == null) return;

    LoggerService().error('Error for $fileId: $error', tag: 'WSFileTransfer');
    _cleanupDownloadSink(download);
    download.completer.completeError(Exception(error));
  }

  void _cleanupDownload(String fileId) {
    final download = _activeDownloads.remove(fileId);
    if (download == null) return;
    _cleanupDownloadSink(download);
  }

  void _cleanupDownloadSink(_ActiveDownload download) {
    try {
      download.fileSink.close();
    } catch (_) {}
    try {
      if (download.tempFile.existsSync()) {
        download.tempFile.deleteSync();
      }
    } catch (_) {}
  }
}

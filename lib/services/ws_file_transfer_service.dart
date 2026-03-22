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
import 'acp_agent_connection.dart';
import 'acp_server_service.dart';
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

  /// Download a file via a client-side ACP connection (app connected TO agent).
  Future<WsFileDownloadResult> downloadViaClientConnection({
    required ACPAgentConnection connection,
    required String fileId,
    void Function(int received, int? total)? onProgress,
  }) async {
    // Create temp file for accumulating chunks
    final tempDir = await _storageService.getStorageDirectory();
    final tempFile = File(path.join(tempDir.path, 'tmp_$fileId'));
    final fileSink = tempFile.openWrite();

    final completer = Completer<WsFileDownloadResult>();
    final download = _ActiveDownload(
      fileId: fileId,
      fileSink: fileSink,
      tempFile: tempFile,
      completer: completer,
      onProgress: onProgress,
    );
    _activeDownloads[fileId] = download;

    // Save previous callbacks so we can chain (support concurrent downloads)
    final prevOnFileChunk = connection.onFileChunk;
    final prevOnFileTransferComplete = connection.onFileTransferComplete;
    final prevOnFileTransferError = connection.onFileTransferError;

    // Wire callbacks
    connection.onFileChunk = (id, chunk) {
      if (_activeDownloads.containsKey(id)) {
        _handleChunk(id, chunk);
      }
      prevOnFileChunk?.call(id, chunk);
    };

    connection.onFileTransferComplete = (id, totalBytes) {
      if (_activeDownloads.containsKey(id)) {
        _handleTransferComplete(id, totalBytes);
      }
      prevOnFileTransferComplete?.call(id, totalBytes);
    };

    connection.onFileTransferError = (id, error) {
      if (_activeDownloads.containsKey(id)) {
        _handleTransferError(id, error);
      }
      prevOnFileTransferError?.call(id, error);
    };

    try {
      // Send the request
      final response = await connection.sendRequest(
        ACPMethod.agentRequestFileData,
        params: {'file_id': fileId},
      );

      if (response.isError) {
        throw Exception(response.error?.message ?? 'Request failed');
      }

      // Extract metadata from response
      final result = response.result as Map<String, dynamic>? ?? {};
      download.filename = result['filename'] as String?;
      download.mimeType = result['mime_type'] as String?;
      download.expectedSize = result['size'] as int? ?? 0;

      // Wait for transfer to complete
      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          _cleanupDownload(fileId);
          throw TimeoutException('File transfer timed out for $fileId');
        },
      );
    } catch (e) {
      _cleanupDownload(fileId);
      rethrow;
    } finally {
      // Restore previous callbacks
      connection.onFileChunk = prevOnFileChunk;
      connection.onFileTransferComplete = prevOnFileTransferComplete;
      connection.onFileTransferError = prevOnFileTransferError;
    }
  }

  /// Download a file via a server-side ACP connection (agent connected TO app).
  Future<WsFileDownloadResult> downloadViaServerConnection({
    required ACPServerService server,
    required String agentId,
    required String fileId,
    void Function(int received, int? total)? onProgress,
  }) async {
    // Create temp file for accumulating chunks
    final tempDir = await _storageService.getStorageDirectory();
    final tempFile = File(path.join(tempDir.path, 'tmp_$fileId'));
    final fileSink = tempFile.openWrite();

    final completer = Completer<WsFileDownloadResult>();
    final download = _ActiveDownload(
      fileId: fileId,
      fileSink: fileSink,
      tempFile: tempFile,
      completer: completer,
      onProgress: onProgress,
    );
    _activeDownloads[fileId] = download;

    // Save previous server callbacks
    final prevOnFileChunk = server.onFileChunk;
    final prevOnFileTransferComplete = server.onFileTransferComplete;
    final prevOnFileTransferError = server.onFileTransferError;

    // Wire callbacks
    server.onFileChunk = (aId, id, chunk) {
      if (_activeDownloads.containsKey(id)) {
        _handleChunk(id, chunk);
      }
      prevOnFileChunk?.call(aId, id, chunk);
    };

    server.onFileTransferComplete = (aId, id, totalBytes) {
      if (_activeDownloads.containsKey(id)) {
        _handleTransferComplete(id, totalBytes);
      }
      prevOnFileTransferComplete?.call(aId, id, totalBytes);
    };

    server.onFileTransferError = (aId, id, error) {
      if (_activeDownloads.containsKey(id)) {
        _handleTransferError(id, error);
      }
      prevOnFileTransferError?.call(aId, id, error);
    };

    try {
      // Send the request to the agent
      final response = await server.sendRequestToAgent(
        agentId,
        ACPMethod.agentRequestFileData,
        params: {'file_id': fileId},
      );

      // Check for error in response
      if (response.containsKey('error') && response['error'] != null) {
        final error = response['error'] as Map<String, dynamic>;
        throw Exception(error['message'] ?? 'Request failed');
      }

      // Extract metadata from response
      final result = response['result'] as Map<String, dynamic>? ?? {};
      download.filename = result['filename'] as String?;
      download.mimeType = result['mime_type'] as String?;
      download.expectedSize = result['size'] as int? ?? 0;

      // Wait for transfer to complete
      return await completer.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          _cleanupDownload(fileId);
          throw TimeoutException('File transfer timed out for $fileId');
        },
      );
    } catch (e) {
      _cleanupDownload(fileId);
      rethrow;
    } finally {
      // Restore previous callbacks
      server.onFileChunk = prevOnFileChunk;
      server.onFileTransferComplete = prevOnFileTransferComplete;
      server.onFileTransferError = prevOnFileTransferError;
    }
  }

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

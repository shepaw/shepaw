import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'local_file_storage_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';
import '../models/message.dart';
import '../models/attachment_data.dart';
import 'package:uuid/uuid.dart';

/// 附件服务
class AttachmentService {
  final LocalFileStorageService _fileStorage;
  final LocalDatabaseService _database;
  final ImagePicker _imagePicker = ImagePicker();
  final _uuid = const Uuid();

  AttachmentService(this._fileStorage, this._database);

  /// 选择图片
  Future<File?> pickImage({ImageSource source = ImageSource.gallery}) async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image == null) return null;

      return File(image.path);
    } catch (e) {
      LoggerService().error('Error picking image', tag: 'Attachment', error: e);
      rethrow;
    }
  }

  /// 选择文件
  Future<File?> pickFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withReadStream: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final filePath = result.files.single.path;
      if (filePath == null) return null;

      return File(filePath);
    } catch (e) {
      LoggerService().error('Error picking file', tag: 'Attachment', error: e);
      rethrow;
    }
  }

  /// 保存附件并创建消息
  Future<Message?> saveAttachment({
    required File file,
    required String channelId,
    required String userId,
    required String userName,
    required String agentId,
  }) async {
    try {
      // 生成唯一文件名
      final extension = path.extension(file.path);
      final fileName = '${_uuid.v4()}$extension';
      
      // 保存文件到本地存储
      final savedPath = await _fileStorage.saveFile(
        file,
        customFileName: fileName,
      );

      if (savedPath == null) {
        throw Exception('Failed to save file');
      }

      // 判断文件类型
      final fileType = _getFileType(file.path);
      int fileSize = await file.length();
      // On some platforms (e.g. macOS sandbox, iCloud Drive) the original path
      // may not be readable after the copy; fall back to the saved copy's size.
      if (fileSize == 0) {
        try {
          final savedFile = await _fileStorage.getFile(savedPath);
          if (savedFile != null) fileSize = await savedFile.length();
        } catch (_) {}
      }

      // 判断消息类型
      MessageType messageType;
      if (fileType == 'image') {
        messageType = MessageType.image;
      } else if (fileType == 'audio') {
        messageType = MessageType.audio;
      } else {
        messageType = MessageType.file;
      }

      // 创建附件消息
      final attachmentData = {
        'path': savedPath,
        'name': path.basename(file.path),
        'type': fileType,
        'size': fileSize,
      };

      final messageId = _uuid.v4();
      final now = DateTime.now();

      final message = Message(
        id: messageId,
        channelId: channelId,
        from: MessageFrom(
          id: userId,
          type: 'user',
          name: userName,
        ),
        type: messageType,
        content: _createAttachmentContent(attachmentData),
        timestampMs: now.millisecondsSinceEpoch,
        metadata: attachmentData,
      );

      // 保存到数据库
      await _database.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: userId,
        senderType: 'user',
        senderName: userName,
        content: message.content,
        messageType: message.type.toString().split('.').last,
        metadata: attachmentData,
      );

      return message;
    } catch (e) {
      LoggerService().error('Error saving attachment', tag: 'Attachment', error: e);
      return null;
    }
  }

  /// 保存语音消息
  Future<Message?> saveVoiceMessage({
    required String filePath,
    required int durationMs,
    required List<double> waveform,
    required String channelId,
    required String userId,
    required String userName,
    required String agentId,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return null;

      final fileSize = await file.length();

      // 保存到 audio 目录
      final savedPath = await _fileStorage.saveFile(
        file,
        type: ResourceType.audio,
      );

      final fileName = savedPath.split('/').last;

      final metadata = {
        'path': savedPath,
        'name': fileName,
        'type': 'audio',
        'size': fileSize,
        'duration_ms': durationMs,
        'waveform': waveform,
      };

      final durationSec = (durationMs / 1000).round();
      final content = 'Voice message (${durationSec}s)';

      final messageId = _uuid.v4();
      final now = DateTime.now();

      final message = Message(
        id: messageId,
        channelId: channelId,
        from: MessageFrom(
          id: userId,
          type: 'user',
          name: userName,
        ),
        type: MessageType.audio,
        content: content,
        timestampMs: now.millisecondsSinceEpoch,
        metadata: metadata,
      );

      await _database.createMessage(
        id: messageId,
        channelId: channelId,
        senderId: userId,
        senderType: 'user',
        senderName: userName,
        content: content,
        messageType: 'audio',
        metadata: metadata,
      );

      // 删除临时文件
      try {
        await file.delete();
      } catch (_) {}

      return message;
    } catch (e) {
      LoggerService().error('Error saving voice message', tag: 'Attachment', error: e);
      return null;
    }
  }

  /// 删除附件
  Future<bool> deleteAttachment(Message message) async {
    try {
      // 删除文件
      if (message.metadata != null && message.metadata!['path'] != null) {
        await _fileStorage.deleteFile(message.metadata!['path']);
      }

      // 删除数据库记录
      await _database.deleteMessage(message.id);

      return true;
    } catch (e) {
      LoggerService().error('Error deleting attachment', tag: 'Attachment', error: e);
      return false;
    }
  }

  /// Build an [AttachmentData] from a saved attachment [Message].
  ///
  /// Reads the file bytes from local storage and constructs the data object
  /// that can be forwarded to an agent. Returns null if the file cannot be read
  /// or the message has no attachment metadata.
  Future<AttachmentData?> buildAttachmentData(Message message) async {
    try {
      final metadata = message.metadata;
      if (metadata == null || metadata['path'] == null) return null;

      final relativePath = metadata['path'] as String;
      final fullPath = await _fileStorage.getFullPath(relativePath);
      final file = File(fullPath);

      if (!await file.exists()) {
        LoggerService().error('Attachment file not found: $fullPath', tag: 'Attachment');
        return null;
      }

      final bytes = await file.readAsBytes();
      final fileName = metadata['name'] as String? ?? path.basename(fullPath);
      final semanticType = metadata['type'] as String? ?? 'file';
      final sizeBytes = metadata['size'] as int? ?? bytes.length;
      final mimeType = _getMimeType(fileName, semanticType);

      // Collect extra metadata (e.g. duration_ms for audio)
      Map<String, dynamic>? extra;
      if (metadata.containsKey('duration_ms')) {
        extra = {'duration_ms': metadata['duration_ms']};
      }

      return AttachmentData(
        fileName: fileName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        bytes: bytes,
        semanticType: semanticType,
        extraMetadata: extra,
      );
    } catch (e) {
      LoggerService().error('Error building attachment data', tag: 'Attachment', error: e);
      return null;
    }
  }

  /// Infer MIME type from file name extension, with [semanticType] as fallback.
  String _getMimeType(String fileName, String semanticType) {
    final ext = path.extension(fileName).toLowerCase();
    const mimeMap = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.gif': 'image/gif',
      '.bmp': 'image/bmp',
      '.webp': 'image/webp',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.avi': 'video/x-msvideo',
      '.mkv': 'video/x-matroska',
      '.webm': 'video/webm',
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
      '.m4a': 'audio/mp4',
      '.aac': 'audio/aac',
      '.ogg': 'audio/ogg',
      '.pdf': 'application/pdf',
      '.doc': 'application/msword',
      '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      '.txt': 'text/plain',
      '.md': 'text/markdown',
    };
    if (mimeMap.containsKey(ext)) return mimeMap[ext]!;

    // Fallback based on semantic type
    return switch (semanticType) {
      'image' => 'image/png',
      'audio' => 'audio/mpeg',
      'video' => 'video/mp4',
      'document' => 'application/octet-stream',
      _ => 'application/octet-stream',
    };
  }

  /// 获取文件类型
  String _getFileType(String filePath) {
    final extension = path.extension(filePath).toLowerCase();
    
    final imageExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp'];
    final videoExtensions = ['.mp4', '.mov', '.avi', '.mkv', '.webm'];
    final audioExtensions = ['.mp3', '.wav', '.m4a', '.aac', '.ogg'];
    final documentExtensions = ['.pdf', '.doc', '.docx', '.txt', '.md'];

    if (imageExtensions.contains(extension)) return 'image';
    if (videoExtensions.contains(extension)) return 'video';
    if (audioExtensions.contains(extension)) return 'audio';
    if (documentExtensions.contains(extension)) return 'document';
    
    return 'file';
  }

  /// 创建附件内容
  String _createAttachmentContent(Map<String, dynamic> attachmentData) {
    final fileName = attachmentData['name'] ?? 'Unknown file';
    final fileType = attachmentData['type'] ?? 'file';
    final fileSize = attachmentData['size'] ?? 0;
    
    // 格式化文件大小
    String formattedSize;
    if (fileSize < 1024) {
      formattedSize = '$fileSize B';
    } else if (fileSize < 1024 * 1024) {
      formattedSize = '${(fileSize / 1024).toStringAsFixed(1)} KB';
    } else {
      formattedSize = '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
    }

    if (fileType == 'image') {
      return '📷 Image: $fileName ($formattedSize)';
    } else if (fileType == 'video') {
      return '🎥 Video: $fileName ($formattedSize)';
    } else if (fileType == 'audio') {
      return '🎵 Audio: $fileName ($formattedSize)';
    } else {
      return '📎 File: $fileName ($formattedSize)';
    }
  }

  /// 格式化文件大小
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

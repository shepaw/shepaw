import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
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
import '../models/store_attachment_ref.dart';
import '../storage/device_identity.dart';
import '../storage/local_store.dart';
import '../storage/store_protocol.dart';
import '../storage/store_service.dart';
import 'package:uuid/uuid.dart';

/// 附件服务
///
/// M5 附件收口（docs/storage_space_plan.md §2/§11）：新附件按内容 hash 编址，
/// 经 store write/commit 落 `<device_id>/attachments/<hash>`（hash 去重，
/// 仅本端可读写）；消息 metadata 记 `hash`，旧 `path` 字段仅作兼容回退。
class AttachmentService {
  final LocalFileStorageService _fileStorage;
  final LocalDatabaseService _database;
  final ImagePicker _imagePicker = ImagePicker();
  final _uuid = const Uuid();

  AttachmentService(this._fileStorage, this._database);

  /// 便捷静态入口（widget 层无注入场景）。
  static AttachmentService get shared =>
      AttachmentService(LocalFileStorageService(), LocalDatabaseService());

  /// 静态解析附件文件（hash 优先，path 兼容回退）。
  static Future<File?> resolveFile(Map<String, dynamic>? metadata) {
    if (metadata == null) return Future.value(null);
    return shared.resolveAttachmentFile(metadata);
  }

  // ────────────────────────────── 附件 store 读写 ──

  /// 附件内容写入 store（hash 去重），返回内容 hash。
  Future<String> _storeAttachmentBytes(Uint8List bytes) async {
    final hash = crypto.sha256.convert(bytes).toString();
    final store = await StoreService.instance.localStore();
    final deviceId = await DeviceIdentity.deviceId();
    // 已存在即去重（内容寻址天然幂等）
    try {
      await store.meta(deviceId, StoreSpace.attachments, hash);
      return hash;
    } on StoreException {
      // not_found → 写入
    }
    final (uploadId, _) = await store.writeBegin(
      deviceId: deviceId,
      space: StoreSpace.attachments,
      path: hash,
      size: bytes.length,
      sha256: hash,
    );
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + LocalStore.maxReadChunk) > bytes.length
          ? bytes.length
          : offset + LocalStore.maxReadChunk;
      await store.writeChunk(
          deviceId, StoreSpace.attachments, uploadId, offset,
          bytes.sublist(offset, end));
      offset = end;
    }
    final (committed, failed) =
        await store.commit(deviceId, StoreSpace.attachments, [uploadId]);
    if (failed.isNotEmpty || committed.isEmpty) {
      throw StateError('attachment commit failed: $failed');
    }
    return hash;
  }

  /// 按 hash 读附件字节。
  Future<Uint8List?> readAttachmentBytes(String hash) async {
    try {
      final store = await StoreService.instance.localStore();
      final deviceId = await DeviceIdentity.deviceId();
      final builder = BytesBuilder(copy: false);
      var offset = 0;
      while (true) {
        final (chunk, _, eof) = await store.read(
            deviceId, StoreSpace.attachments, hash, offset,
            LocalStore.maxReadChunk);
        builder.add(chunk);
        offset += chunk.length;
        if (eof || chunk.isEmpty) break;
      }
      return builder.toBytes();
    } catch (_) {
      return null;
    }
  }

  /// 解析附件文件（消息气泡展示用）：
  /// store_uri 引用 → hash 编址 attachments → 旧 path 兼容回退。
  Future<File?> resolveAttachmentFile(Map<String, dynamic> metadata) async {
    final storeUri = metadata['store_uri'] as String?;
    if (storeUri != null && storeUri.isNotEmpty) {
      return StoreAttachmentRef.fileFromStoreUri(storeUri);
    }
    final hash = metadata['hash'] as String?;
    if (hash != null && hash.isNotEmpty) {
      try {
        final store = await StoreService.instance.localStore();
        final deviceId = await DeviceIdentity.deviceId();
        final f = File(path.join(
            store.root.path, deviceId, StoreSpace.attachments, hash));
        if (await f.exists()) return f;
        return null;
      } catch (_) {
        return null;
      }
    }
    final legacyPath = metadata['path'] as String?;
    if (legacyPath != null && legacyPath.isNotEmpty) {
      final full = await _fileStorage.getFullPath(legacyPath);
      final f = File(full);
      if (await f.exists()) return f;
    }
    return null;
  }

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

  /// 保存附件并创建消息。
  ///
  /// [storeUri] 非空时引用储物袋已有文件，不复制到 attachments 空间。
  Future<Message?> saveAttachment({
    required File file,
    String? storeUri,
    String? displayName,
    required String channelId,
    required String userId,
    required String userName,
    required String agentId,
  }) async {
    try {
      if (!await file.exists()) return null;

      final name = displayName ?? path.basename(file.path);
      final fileType = _getFileType(name);
      final fileSize = await file.length();

      final Map<String, dynamic> attachmentData;
      if (storeUri != null && storeUri.isNotEmpty) {
        attachmentData = {
          'store_uri': storeUri,
          'name': name,
          'type': fileType,
          'size': fileSize,
        };
      } else {
        // M5：系统文件按内容 hash 编址写入 store（去重，仅本端可读写）
        final bytes = await file.readAsBytes();
        final hash = await _storeAttachmentBytes(bytes);
        attachmentData = {
          'hash': hash,
          'name': name,
          'type': fileType,
          'size': fileSize,
        };
      }

      MessageType messageType;
      if (fileType == 'image') {
        messageType = MessageType.image;
      } else if (fileType == 'audio') {
        messageType = MessageType.audio;
      } else {
        messageType = MessageType.file;
      }

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

      // M5：语音同样按 hash 编址写入 store
      final bytes = await file.readAsBytes();
      final hash = await _storeAttachmentBytes(bytes);

      final metadata = {
        'hash': hash,
        'name': path.basename(filePath),
        'type': 'audio',
        'size': bytes.length,
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
      if (metadata == null) return null;

      // store_uri 引用 → hash 编址 attachments → 旧 path 兼容回退
      Uint8List? bytes;
      String? fallbackName;
      final storeUri = metadata['store_uri'] as String?;
      if (storeUri != null && storeUri.isNotEmpty) {
        final file = await StoreAttachmentRef.fileFromStoreUri(storeUri);
        if (file == null) {
          LoggerService().error('Store attachment not found: $storeUri',
              tag: 'Attachment');
          return null;
        }
        bytes = await file.readAsBytes();
        fallbackName = path.basename(file.path);
      } else {
        final hash = metadata['hash'] as String?;
        if (hash != null && hash.isNotEmpty) {
          bytes = await readAttachmentBytes(hash);
          if (bytes == null) {
            LoggerService().error('Attachment blob not found: $hash',
                tag: 'Attachment');
            return null;
          }
        } else if (metadata['path'] != null) {
          final relativePath = metadata['path'] as String;
          final fullPath = await _fileStorage.getFullPath(relativePath);
          final file = File(fullPath);
          if (!await file.exists()) {
            LoggerService().error('Attachment file not found: $fullPath',
                tag: 'Attachment');
            return null;
          }
          bytes = await file.readAsBytes();
          fallbackName = path.basename(fullPath);
        } else {
          return null;
        }
      }

      final fileName =
          metadata['name'] as String? ?? fallbackName ?? 'attachment';
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

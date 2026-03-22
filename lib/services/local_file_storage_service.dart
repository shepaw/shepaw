import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import 'dart:typed_data';
import 'logger_service.dart';

/// 本地文件存储服务 - 管理图片、头像等资源文件
class LocalFileStorageService {
  static final LocalFileStorageService _instance = LocalFileStorageService._internal();
  factory LocalFileStorageService() => _instance;
  LocalFileStorageService._internal();

  final _uuid = const Uuid();

  /// 获取应用数据目录
  Future<Directory> get _appDataDir async {
    final directory = await getApplicationDocumentsDirectory();
    final appDir = Directory(path.join(directory.path, 'shepaw'));
    if (!await appDir.exists()) {
      await appDir.create(recursive: true);
    }
    return appDir;
  }

  /// 获取存储目录（公共方法）
  Future<Directory> getStorageDirectory() async {
    return _appDataDir;
  }

  /// 获取资源目录
  Future<Directory> _getResourceDirectory(ResourceType type) async {
    final appDir = await _appDataDir;
    final resourceDir = Directory(path.join(appDir.path, type.folderName));
    if (!await resourceDir.exists()) {
      await resourceDir.create(recursive: true);
    }
    return resourceDir;
  }

  // ==================== 图片/头像存储 ====================

  /// 保存图片文件
  /// 返回相对路径（相对于应用数据目录）
  Future<String> saveImage(File imageFile, {ResourceType type = ResourceType.avatars}) async {
    final resourceDir = await _getResourceDirectory(type);
    final extension = path.extension(imageFile.path);
    final fileName = '${_uuid.v4()}$extension';
    final targetPath = path.join(resourceDir.path, fileName);
    
    await imageFile.copy(targetPath);
    
    // 返回相对路径
    return '${type.folderName}/$fileName';
  }

  /// 保存图片数据（字节流）
  Future<String> saveImageBytes(Uint8List bytes, String extension, {ResourceType type = ResourceType.avatars}) async {
    final resourceDir = await _getResourceDirectory(type);
    final fileName = '${_uuid.v4()}.$extension';
    final targetPath = path.join(resourceDir.path, fileName);
    
    final file = File(targetPath);
    await file.writeAsBytes(bytes);
    
    // 返回相对路径
    return '${type.folderName}/$fileName';
  }

  /// 获取图片的完整路径
  Future<String> getFullPath(String relativePath) async {
    final appDir = await _appDataDir;
    return path.join(appDir.path, relativePath);
  }

  /// 获取图片文件
  Future<File?> getImageFile(String relativePath) async {
    final fullPath = await getFullPath(relativePath);
    final file = File(fullPath);
    return await file.exists() ? file : null;
  }

  /// 删除图片文件
  Future<void> deleteImage(String relativePath) async {
    final fullPath = await getFullPath(relativePath);
    final file = File(fullPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  // ==================== 通用文件操作 ====================

  /// 保存任意文件
  Future<String> saveFile(
    File sourceFile, {
    ResourceType type = ResourceType.documents,
    String? customFileName,
  }) async {
    final resourceDir = await _getResourceDirectory(type);
    final extension = path.extension(sourceFile.path);
    final fileName = customFileName ?? '${_uuid.v4()}$extension';
    final targetPath = path.join(resourceDir.path, fileName);
    
    await sourceFile.copy(targetPath);
    
    // 返回相对路径
    return '${type.folderName}/$fileName';
  }

  /// 读取文件
  Future<File?> getFile(String relativePath) async {
    final fullPath = await getFullPath(relativePath);
    final file = File(fullPath);
    return await file.exists() ? file : null;
  }

  /// 删除文件
  Future<void> deleteFile(String relativePath) async {
    final fullPath = await getFullPath(relativePath);
    final file = File(fullPath);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 获取文件大小
  Future<int?> getFileSize(String relativePath) async {
    final file = await getFile(relativePath);
    return file != null ? await file.length() : null;
  }

  // ==================== 目录管理 ====================

  /// 获取某类型资源的所有文件
  Future<List<File>> listFiles(ResourceType type) async {
    final resourceDir = await _getResourceDirectory(type);
    final entities = await resourceDir.list().toList();
    return entities.whereType<File>().toList();
  }

  /// 清空某类型的所有文件
  Future<void> clearResourceType(ResourceType type) async {
    final resourceDir = await _getResourceDirectory(type);
    if (await resourceDir.exists()) {
      await resourceDir.delete(recursive: true);
      await resourceDir.create();
    }
  }

  /// 清空所有资源文件
  Future<void> clearAllResources() async {
    final appDir = await _appDataDir;
    if (await appDir.exists()) {
      await appDir.delete(recursive: true);
      await appDir.create();
    }
  }

  /// 获取资源使用情况统计
  Future<StorageStats> getStorageStats() async {
    int totalSize = 0;
    int fileCount = 0;
    Map<ResourceType, int> sizeByType = {};
    Map<ResourceType, int> countByType = {};

    for (final type in ResourceType.values) {
      final dir = await _getResourceDirectory(type);
      if (await dir.exists()) {
        final files = await listFiles(type);
        int typeSize = 0;
        for (final file in files) {
          final size = await file.length();
          typeSize += size;
          totalSize += size;
        }
        sizeByType[type] = typeSize;
        countByType[type] = files.length;
        fileCount += files.length;
      } else {
        sizeByType[type] = 0;
        countByType[type] = 0;
      }
    }

    return StorageStats(
      totalSize: totalSize,
      fileCount: fileCount,
      sizeByType: sizeByType,
      countByType: countByType,
    );
  }

  // ==================== 头像助手方法 ====================

  /// 保存 Agent 头像
  Future<String> saveAgentAvatar(File imageFile) async {
    return await saveImage(imageFile, type: ResourceType.avatars);
  }

  /// 保存 Channel 头像
  Future<String> saveChannelAvatar(File imageFile) async {
    return await saveImage(imageFile, type: ResourceType.avatars);
  }

  /// 保存用户头像
  Future<String> saveUserAvatar(File imageFile) async {
    return await saveImage(imageFile, type: ResourceType.avatars);
  }

  // ==================== 缩略图生成（可选） ====================

  /// 创建图片缩略图
  Future<String?> createThumbnail(String originalPath, {int maxWidth = 200}) async {
    try {
      final originalFile = await getFile(originalPath);
      if (originalFile == null) return null;

      // 这里可以集成图片压缩库（如 image 或 flutter_image_compress）
      // 简化版：直接复制原图作为缩略图
      final thumbnailPath = await saveImage(
        originalFile,
        type: ResourceType.thumbnails,
      );
      
      return thumbnailPath;
    } catch (e) {
      LoggerService().error('Failed to create thumbnail', tag: 'FileStorage', error: e);
      return null;
    }
  }
}

/// 资源类型枚举
enum ResourceType {
  avatars('avatars'),           // 头像
  images('images'),             // 一般图片
  documents('documents'),       // 文档
  thumbnails('thumbnails'),     // 缩略图
  audio('audio'),               // 音频
  temp('temp');                 // 临时文件

  final String folderName;
  const ResourceType(this.folderName);
}

/// 存储统计信息
class StorageStats {
  final int totalSize;          // 总大小（字节）
  final int fileCount;          // 文件总数
  final Map<ResourceType, int> sizeByType;    // 按类型统计大小
  final Map<ResourceType, int> countByType;   // 按类型统计数量

  StorageStats({
    required this.totalSize,
    required this.fileCount,
    required this.sizeByType,
    required this.countByType,
  });

  /// 转换为人类可读的大小
  String get readableSize => _formatBytes(totalSize);

  String getReadableSizeByType(ResourceType type) {
    return _formatBytes(sizeByType[type] ?? 0);
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  String toString() {
    return 'StorageStats(totalSize: $readableSize, fileCount: $fileCount)';
  }
}

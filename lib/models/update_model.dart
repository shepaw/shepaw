/// 应用更新相关的数据模型

// ignore_for_file: dangling_library_doc_comments

/// 版本信息
class VersionInfo implements Comparable<VersionInfo> {
  final int major;
  final int minor;
  final int patch;
  final int buildNumber;

  VersionInfo({
    required this.major,
    required this.minor,
    required this.patch,
    required this.buildNumber,
  });

  /// 从字符串解析版本号，格式：1.2.3+4
  factory VersionInfo.parse(String version) {
    final parts = version.split('+');
    final versionParts = parts[0].split('.');
    
    return VersionInfo(
      major: int.tryParse(versionParts.elementAt(0)) ?? 0,
      minor: int.tryParse(versionParts.elementAt(1)) ?? 0,
      patch: int.tryParse(versionParts.elementAt(2)) ?? 0,
      buildNumber: int.tryParse(parts.elementAt(1)) ?? 0,
    );
  }

  /// 获取版本号字符串，格式：1.2.3
  String get versionString => '$major.$minor.$patch';

  /// 获取完整版本号字符串，格式：1.2.3+4
  String get fullVersionString => '$versionString+$buildNumber';

  /// 检查是否有更新可用（传入的版本号高于当前版本）
  bool isLowerThan(VersionInfo other) {
    if (major != other.major) return major < other.major;
    if (minor != other.minor) return minor < other.minor;
    if (patch != other.patch) return patch < other.patch;
    return buildNumber < other.buildNumber;
  }

  /// 检查是否是主要版本更新
  bool isMajorUpdate(VersionInfo other) {
    return major != other.major;
  }

  /// 检查是否是次要版本更新
  bool isMinorUpdate(VersionInfo other) {
    return major == other.major && minor != other.minor;
  }

  @override
  int compareTo(VersionInfo other) {
    if (isLowerThan(other)) return -1;
    if (other.isLowerThan(this)) return 1;
    return 0;
  }

  @override
  String toString() => fullVersionString;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is VersionInfo &&
            runtimeType == other.runtimeType &&
            major == other.major &&
            minor == other.minor &&
            patch == other.patch &&
            buildNumber == other.buildNumber;
  }

  @override
  int get hashCode =>
      major.hashCode ^ minor.hashCode ^ patch.hashCode ^ buildNumber.hashCode;
}

/// 下载进度信息
class DownloadProgress {
  /// 已下载字节数
  final int downloadedBytes;

  /// 总字节数（可能为 null 如果服务器未提供）
  final int? totalBytes;

  /// 下载百分比 (0-100)
  int get percentage {
    if (totalBytes == null || totalBytes == 0) return 0;
    return ((downloadedBytes / totalBytes!) * 100).toInt();
  }

  /// 是否已完成
  bool get isComplete => totalBytes != null && downloadedBytes >= totalBytes!;

  /// 格式化的进度字符串
  String get formattedProgress {
    if (totalBytes == null) {
      return formatBytes(downloadedBytes);
    }
    return '${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes!)}';
  }

  DownloadProgress({
    required this.downloadedBytes,
    required this.totalBytes,
  });

  /// 格式化字节数为易读格式
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}

/// 更新下载状态
enum UpdateDownloadState {
  idle,           // 未开始
  downloading,    // 下载中
  completed,      // 完成
  failed,         // 失败
}

/// 更新信息（从远程服务器获取）
class UpdateInfo {
  /// 最新版本号，格式：1.2.3+4
  final String version;

  /// 版本描述/更新日志
  final String description;

  /// 是否为必须更新
  final bool isMandatory;

  /// 发布时间（ISO 8601 格式，如：2024-03-24T10:30:00Z）
  final String releaseDate;

  /// 下载链接
  final String downloadUrl;

  /// 更新大小（字节）
  final int? fileSize;

  /// 校验和（用于验证下载完整性）
  final String? checksum;

  /// 支持的最低iOS版本
  final String? minIosVersion;

  /// 支持的最低Android版本
  final int? minAndroidSdk;

  /// 支持的最低macOS版本
  final String? minMacOSVersion;

  /// 支持的最低Windows版本
  final String? minWindowsVersion;

  UpdateInfo({
    required this.version,
    required this.description,
    required this.isMandatory,
    required this.releaseDate,
    required this.downloadUrl,
    this.fileSize,
    this.checksum,
    this.minIosVersion,
    this.minAndroidSdk,
    this.minMacOSVersion,
    this.minWindowsVersion,
  });

  /// 从JSON解析
  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: json['version'] as String? ?? '0.0.0+0',
      description: json['description'] as String? ?? '',
      isMandatory: json['isMandatory'] as bool? ?? false,
      releaseDate: json['releaseDate'] as String? ?? '',
      downloadUrl: json['downloadUrl'] as String? ?? '',
      fileSize: json['fileSize'] as int?,
      checksum: json['checksum'] as String?,
      minIosVersion: json['minIosVersion'] as String?,
      minAndroidSdk: json['minAndroidSdk'] as int?,
      minMacOSVersion: json['minMacOSVersion'] as String?,
      minWindowsVersion: json['minWindowsVersion'] as String?,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'description': description,
      'isMandatory': isMandatory,
      'releaseDate': releaseDate,
      'downloadUrl': downloadUrl,
      'fileSize': fileSize,
      'checksum': checksum,
      'minIosVersion': minIosVersion,
      'minAndroidSdk': minAndroidSdk,
      'minMacOSVersion': minMacOSVersion,
      'minWindowsVersion': minWindowsVersion,
    };
  }
}

/// 更新检查结果
class UpdateCheckResult {
  /// 是否有更新可用
  final bool hasUpdate;

  /// 更新信息（如果有更新）
  final UpdateInfo? updateInfo;

  /// 错误消息（如果检查失败）
  final String? error;

  /// 检查时间戳
  final DateTime timestamp;

  UpdateCheckResult({
    required this.hasUpdate,
    this.updateInfo,
    this.error,
    required this.timestamp,
  });

  /// 检查是否失败
  bool get isFailed => error != null && !hasUpdate;

  /// 是否是必须更新
  bool get isMandatory => hasUpdate && updateInfo?.isMandatory == true;
}

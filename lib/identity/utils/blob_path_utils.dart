import 'package:path/path.dart' as p;

/// Blob / 附件相对路径校验，防止 `..` 与绝对路径穿越存储根目录。
class BlobPathUtils {
  BlobPathUtils._();

  static const maxPathLength = 512;

  /// 是否为合法的账号域内相对存储路径。
  static bool isValidRelativeStoragePath(String relativePath) {
    if (relativePath.isEmpty || relativePath.length > maxPathLength) return false;
    if (relativePath.contains('\0')) return false;
    if (relativePath.startsWith('/') || relativePath.startsWith('\\')) return false;
    if (RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(relativePath)) return false;

    final normalized = relativePath.replaceAll('\\', '/');
    for (final segment in normalized.split('/')) {
      if (segment == '..') return false;
    }
    return true;
  }

  static void validateOrThrow(String relativePath) {
    if (!isValidRelativeStoragePath(relativePath)) {
      throw ArgumentError('invalid blob storage path: $relativePath');
    }
  }

  /// 将 [relativePath] 解析为 [rootDir] 下的绝对路径；若越界则返回 null。
  static String? resolveUnderRoot(String rootDir, String relativePath) {
    if (!isValidRelativeStoragePath(relativePath)) return null;
    final full = p.normalize(p.join(rootDir, relativePath));
    if (!p.isWithin(rootDir, full) && full != p.normalize(rootDir)) {
      return null;
    }
    return full;
  }
}

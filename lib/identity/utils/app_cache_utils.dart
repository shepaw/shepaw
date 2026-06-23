import 'dart:convert';

/// App 设备消息正文缓存字节估算。
class AppCacheUtils {
  AppCacheUtils._();

  static int estimateMessageRowBytes(Map<String, dynamic> row) {
    final content = row['content'] as String? ?? '';
    final metadata = row['metadata'] as String? ?? '';
    return utf8.encode(content).length + utf8.encode(metadata).length;
  }
}

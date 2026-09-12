import 'dart:io';

import 'package:crypto/crypto.dart';

/// 校验更新包完整性。清单里的 `checksum` 形如 `sha256:<hex>`。
class UpdateChecksum {
  /// 没有声明 checksum 时视为跳过（兼容旧清单）。
  static bool get skipWhenMissing => true;

  /// 从 `sha256:abcd` / `SHA256:ABCD` / 裸 hex 中取出小写 hex；无法识别则返回 null。
  static String? parseExpectedHex(String? checksum) {
    if (checksum == null) return null;
    final trimmed = checksum.trim();
    if (trimmed.isEmpty) return null;

    final raw = trimmed.contains(':')
        ? trimmed.substring(trimmed.indexOf(':') + 1).trim()
        : trimmed;
    final hex = raw.toLowerCase();
    if (hex.length != 64 || !RegExp(r'^[0-9a-f]+$').hasMatch(hex)) {
      return null;
    }
    return hex;
  }

  static String hexOf(Digest digest) => digest.toString();

  static bool matchesBytes(List<int> bytes, String? checksum) {
    final expected = parseExpectedHex(checksum);
    if (expected == null) return skipWhenMissing && (checksum == null || checksum.trim().isEmpty);
    return hexOf(sha256.convert(bytes)) == expected;
  }

  static Future<bool> matchesFile(File file, String? checksum) async {
    final expected = parseExpectedHex(checksum);
    if (expected == null) {
      return skipWhenMissing && (checksum == null || checksum.trim().isEmpty);
    }
    final digest = await sha256.bind(file.openRead()).single;
    return hexOf(digest) == expected;
  }
}

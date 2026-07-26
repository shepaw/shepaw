import 'dart:io';

import '../services/logger_service.dart';

/// 存储根所在卷的容量探测（方案 §7 / §12：master 磁盘 80% 告警）。
///
/// 优先用 `df -kP`（macOS / Linux / 多数 Android）；失败则返回 null，
/// UI 降级为不展示卷告警（不引入新原生依赖）。
class VolumeUsage {
  VolumeUsage({required this.totalBytes, required this.freeBytes});

  final int totalBytes;
  final int freeBytes;

  /// 已用比例 ∈ [0, 1]。
  double get usedRatio {
    if (totalBytes <= 0) return 0;
    final used = totalBytes - freeBytes;
    if (used <= 0) return 0;
    if (used >= totalBytes) return 1;
    return used / totalBytes;
  }

  /// 方案决策：≥ 80% 显著告警。
  static const warnRatio = 0.8;

  bool get needsAttention => usedRatio >= warnRatio;

  static const _tag = 'VolumeUsage';

  /// 探测 [path] 所在卷；不可用时返回 null。
  static Future<VolumeUsage?> probe(String path) async {
    try {
      if (Platform.isWindows) {
        return await _probeWindows(path);
      }
      return await _probeUnix(path);
    } catch (e) {
      LoggerService().debug('volume probe failed: $e', tag: _tag);
      return null;
    }
  }

  static Future<VolumeUsage?> _probeUnix(String path) async {
    final result = await Process.run('df', ['-kP', path]);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String?) ?? '';
    return parseDfKP(out);
  }

  /// 解析 `df -kP` 输出（POSIX）。测试可直接调用。
  static VolumeUsage? parseDfKP(String stdout) {
    final lines = stdout
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    // 跳过表头；取第一条数据行（路径可能含空格时 Capacity 仍可解析）
    for (var i = 1; i < lines.length; i++) {
      final parts = lines[i].split(RegExp(r'\s+'));
      // Filesystem 1024-blocks Used Available Capacity Mounted...
      if (parts.length < 5) continue;
      final totalK = int.tryParse(parts[1]);
      final availK = int.tryParse(parts[3]);
      if (totalK == null || availK == null || totalK <= 0) continue;
      return VolumeUsage(
        totalBytes: totalK * 1024,
        freeBytes: availK * 1024,
      );
    }
    return null;
  }

  static Future<VolumeUsage?> _probeWindows(String path) async {
    // 取盘符，如 C:\foo → C:
    final root = path.length >= 2 && path[1] == ':'
        ? '${path[0].toUpperCase()}:'
        : null;
    if (root == null) return null;
    final result = await Process.run('wmic', [
      'logicaldisk',
      'where',
      "DeviceID='$root'",
      'get',
      'FreeSpace,Size',
      '/format:value',
    ]);
    if (result.exitCode != 0) return null;
    return parseWmicValue(result.stdout as String? ?? '');
  }

  /// 解析 `wmic ... /format:value` 输出。测试可直接调用。
  static VolumeUsage? parseWmicValue(String stdout) {
    int? free;
    int? size;
    for (final raw in stdout.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('FreeSpace=')) {
        free = int.tryParse(line.substring('FreeSpace='.length));
      } else if (line.startsWith('Size=')) {
        size = int.tryParse(line.substring('Size='.length));
      }
    }
    if (free == null || size == null || size <= 0) return null;
    return VolumeUsage(totalBytes: size, freeBytes: free);
  }
}

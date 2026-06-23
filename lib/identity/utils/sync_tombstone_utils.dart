/// Tombstone 修剪窗口：兼顾离线设备 pull 与存储上限。
class SyncTombstoneUtils {
  SyncTombstoneUtils._();

  static const minRetentionMs = 30 * 86400000;
  static const maxRetentionMs = 90 * 86400000;

  /// 计算可安全 prune 的 tombstone 截止 wall_time（早于此时间的 tombstone 可删）。
  ///
  /// 保留窗口 = clamp(max(30天, 各设备离线时长), max=90天)。
  static int pruneCutoffWallTimeMs({
    required int nowMs,
    required Iterable<int> deviceLastSeenMs,
    int minRetentionMs = SyncTombstoneUtils.minRetentionMs,
    int maxRetentionMs = SyncTombstoneUtils.maxRetentionMs,
  }) {
    var retentionMs = minRetentionMs;
    for (final lastSeen in deviceLastSeenMs) {
      final offlineMs = nowMs - lastSeen;
      if (offlineMs > retentionMs) retentionMs = offlineMs;
    }
    if (retentionMs > maxRetentionMs) retentionMs = maxRetentionMs;
    return nowMs - retentionMs;
  }
}

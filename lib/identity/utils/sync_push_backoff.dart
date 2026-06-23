/// Primary → App/Backup sync_push outbox 指数退避。
class SyncPushBackoff {
  SyncPushBackoff._();

  static const int baseDelayMs = 5000;
  static const int maxDelayMs = 300000;

  /// [retryCount] 为已失败次数（1 = 首次失败后等待 baseDelay）。
  static int delayMsForRetryCount(int retryCount) {
    if (retryCount <= 0) return 0;
    final shift = retryCount - 1;
    if (shift >= 31) return maxDelayMs;
    final delay = baseDelayMs * (1 << shift);
    return delay > maxDelayMs ? maxDelayMs : delay;
  }

  static int nextRetryAtMs(int retryCount, int nowMs) =>
      nowMs + delayMsForRetryCount(retryCount);
}

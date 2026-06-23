/// sync_push 批次 apply 结果（接收方 → Primary ack）。
class SyncPushApplyResult {
  final bool allApplied;
  final List<String> failedEventIds;

  const SyncPushApplyResult({
    required this.allApplied,
    this.failedEventIds = const [],
  });

  static const ok = SyncPushApplyResult(allApplied: true);
}

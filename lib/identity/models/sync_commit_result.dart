/// Primary 对 App [sync_commit] 的处理结果。
class SyncCommitResult {
  final bool ok;
  final bool applied;

  /// Primary 已有更新版本，拒绝写入但仍视为队列可 ack。
  final bool stale;

  const SyncCommitResult({
    required this.ok,
    this.applied = false,
    this.stale = false,
  });

  static const failed = SyncCommitResult(ok: false);

  static SyncCommitResult appliedOk() =>
      const SyncCommitResult(ok: true, applied: true);

  static SyncCommitResult staleOk() =>
      const SyncCommitResult(ok: true, stale: true);

  /// Backup relay 队列：仅 Primary 已持久化（applied）时 ack，stale 需保留重试/pull。
  static bool shouldAckBackupRelayResponse(Map<String, dynamic>? resp) {
    if (resp?['ok'] != true) return false;
    if (resp?['stale'] == true) return false;
    if (resp?['applied'] == true) return true;
    // legacy Primary without applied/stale fields
    return resp?['applied'] == null && resp?['stale'] != true;
  }
}

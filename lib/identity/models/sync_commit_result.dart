/// Primary 对 App [sync_commit] 的处理结果。
class SyncCommitResult {
  final bool ok;
  final bool applied;

  /// Primary 已有更新版本，拒绝写入但仍视为队列可 ack。
  final bool stale;

  /// Backup 已暂存 relay 队列，Primary 尚未确认；App outbound 不可 ack。
  final bool pendingRelay;

  const SyncCommitResult({
    required this.ok,
    this.applied = false,
    this.stale = false,
    this.pendingRelay = false,
  });

  static const failed = SyncCommitResult(ok: false);

  static SyncCommitResult appliedOk() =>
      const SyncCommitResult(ok: true, applied: true);

  static SyncCommitResult staleOk() =>
      const SyncCommitResult(ok: true, stale: true);

  static SyncCommitResult pendingRelayOk() =>
      const SyncCommitResult(ok: true, pendingRelay: true);

  Map<String, dynamic> toCommitResponse({required String requestId}) => {
        'type': 'sync_commit_resp',
        'request_id': requestId,
        'ok': ok,
        'applied': applied,
        if (stale) 'stale': true,
        if (pendingRelay) 'pending_relay': true,
      };

  /// App outbound：Primary 已确认或 stale 时可 ack；pending_relay 必须保留重试。
  static bool shouldAckOutboundCommitResponse(Map<String, dynamic>? resp) {
    if (resp?['ok'] != true) return false;
    if (resp?['pending_relay'] == true) return false;
    if (resp?['stale'] == true) return true;
    if (resp?['applied'] == true) return true;
    // legacy Primary without applied/stale fields
    return resp?['applied'] == null && resp?['stale'] != true;
  }

  /// Backup relay 队列：仅 Primary 已持久化（applied）时 ack，stale 需保留重试/pull。
  static bool shouldAckBackupRelayResponse(Map<String, dynamic>? resp) {
    if (resp?['ok'] != true) return false;
    if (resp?['stale'] == true) return false;
    if (resp?['applied'] == true) return true;
    // legacy Primary without applied/stale fields
    return resp?['applied'] == null && resp?['stale'] != true;
  }
}

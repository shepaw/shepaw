/// sync apply 单条事件的处理结果。
enum SyncApplyOutcome {
  /// 已写入本地并应记录 entity state。
  applied,

  /// LWW 判定为 stale，跳过写入但应推进 pull 游标。
  staleSkipped,

  /// 无效 payload，跳过写入但应推进 pull 游标以免 head-of-line 阻塞。
  invalidSkipped,
}

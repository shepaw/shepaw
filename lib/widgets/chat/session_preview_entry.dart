/// 会话列表一行的预览缓存（首条 / 最新 / 未读 / 群编排快照）。
///
/// 缓存在 [ChatScreen] 上跨抽屉路由存活：移动端关掉抽屉会 dispose 列表
/// State，但条目留在这里，下次划开首帧就能画出标题和预览，不必再闪占位。
class SessionPreviewEntry {
  /// `(first, latest, unread, orchestration?)`；null = 尚未查到。
  (Map<String, dynamic>?, Map<String, dynamic>?, int, Map<String, dynamic>?)?
      data;

  /// true = 数据可能过期，待下一次构建时后台重查。
  bool stale = true;

  /// true = 后台重查进行中（避免重复发起）。
  bool refreshing = false;
}

/// 切换当前会话时，只把离开和进入的两行标过期。
///
/// 其余行的预览（标题、最新消息、未读）没有变，不必整表重查。
void markSwitchedSessionPreviewsStale(
  Map<String, SessionPreviewEntry> previews, {
  required String? fromChannelId,
  required String? toChannelId,
}) {
  if (fromChannelId == toChannelId) return;
  if (fromChannelId != null) previews[fromChannelId]?.stale = true;
  if (toChannelId != null) previews[toChannelId]?.stale = true;
}

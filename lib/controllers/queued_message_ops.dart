import '../models/queued_message.dart';

/// 纯函数助手：待发送队列的逐条编辑/删除/重排。
///
/// 与 [ChatSendPlanner] 同一约定：无状态、原地变更传入的列表、以 `bool`
/// 表达是否命中。列表是 ChatService 侧 `pendingSendQueue(...)` 返回的活列表，
/// 原地变更保证引用始终有效。
class QueuedMessageOps {
  QueuedMessageOps._();

  /// 更新 [id] 对应的消息内容。trim 后为空视为非法（拒绝空消息入队）。
  /// 返回是否命中。
  static bool edit(List<QueuedMessage> queue, String id, String newContent) {
    final trimmed = newContent.trim();
    if (trimmed.isEmpty) return false;
    final idx = queue.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    queue[idx].content = trimmed;
    return true;
  }

  /// 删除 [id] 对应的消息。返回是否命中。
  static bool remove(List<QueuedMessage> queue, String id) {
    final idx = queue.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    queue.removeAt(idx);
    return true;
  }

  /// 将 [id] 对应的消息移动 [delta] 位（上移 -1 / 下移 +1）。
  /// 目标下标越界、`delta == 0` 或未命中时返回 false。
  static bool move(List<QueuedMessage> queue, String id, int delta) {
    if (delta == 0) return false;
    final idx = queue.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    final target = idx + delta;
    if (target < 0 || target >= queue.length) return false;
    final item = queue.removeAt(idx);
    queue.insert(target, item);
    return true;
  }
}

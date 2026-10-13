/// 把一张交互卡收成不可点，并写进消息 metadata。
///
/// 作废帧以前只通知当前打开的 [ChatController]。页面不在、或者进程重启后
/// 内存账簿是空的，SQLite 里的卡片就还是可点的。这里的纯函数负责「这张卡
/// 该不该改、改成什么样」，写库的人拿它的返回值去落库。
library;

/// 审批卡作废时写入的选择哨兵。不是用户点的。
///
/// cli 审批卡和待对账逻辑都把非空 `selected_action_id` 当成「已经收场」。
/// 作废不是回答，但得占上这个位置，否则重启后对账还会把它当成待处理。
const String kExpiredActionId = 'expired';

/// 用户真的答过这张卡（点了按钮，或提交了表单）。
///
/// `expired` 不算。作废和作答撞在一起时，裁决留下，不改写成「没答」。
bool interactionHasVerdict(Map<dynamic, dynamic> data) {
  if (data['submitted_values'] != null) return true;
  final selected = data['selected_action_id'];
  return selected != null && selected != kExpiredActionId;
}

/// 按交互 id 把这张消息上的审批卡或表单卡收起来。
///
/// 消息上没有这张卡、已经答过、或已经作废过，返回 null（调用方不要写库，
/// 免得用一轮较晚的 `turn_ended` 盖掉更具体的 `timeout`）。
Map<String, dynamic>? metadataClosingInteraction(
  Map<String, dynamic> metadata, {
  required String interactionId,
  required String reason,
}) {
  if (interactionId.isEmpty) return null;
  final next = Map<String, dynamic>.from(metadata);
  var changed = false;
  for (final key in const ['action_confirmation', 'form']) {
    final raw = next[key];
    if (raw is! Map || !_holdsInteraction(raw, interactionId)) continue;
    final closed = _closeCard(raw, reason, approval: key == 'action_confirmation');
    if (closed == null) continue;
    next[key] = closed;
    changed = true;
  }
  return changed ? next : null;
}

/// 回合已经结束，但这边已经没有卡片 id（进程被杀掉后内存账簿是空的）。
///
/// 只动还开着的审批卡和表单卡。答过的、已经写过 `closed` 的不动。
Map<String, dynamic>? metadataClosingOpenCards(
  Map<String, dynamic> metadata, {
  required String reason,
}) {
  final next = Map<String, dynamic>.from(metadata);
  var changed = false;
  for (final key in const ['action_confirmation', 'form']) {
    final raw = next[key];
    if (raw is! Map) continue;
    final closed = _closeCard(raw, reason, approval: key == 'action_confirmation');
    if (closed == null) continue;
    next[key] = closed;
    changed = true;
  }
  return changed ? next : null;
}

bool _holdsInteraction(Map<dynamic, dynamic> data, String interactionId) {
  if (data['confirmation_id'] == interactionId) return true;
  if (data['form_id'] == interactionId) return true;
  final peer = data['peer_form'];
  return peer is Map && peer['approval_id'] == interactionId;
}

/// 返回收起来之后的卡片；不该动时返回 null。
Map<String, dynamic>? _closeCard(
  Map<dynamic, dynamic> raw,
  String reason, {
  required bool approval,
}) {
  final data = Map<String, dynamic>.from(raw);
  if (interactionHasVerdict(data)) return null;
  if (data['closed'] != null) return null;
  data['closed'] = reason;
  if (approval && data['selected_action_id'] == null) {
    data['selected_action_id'] = kExpiredActionId;
    data['selected_action_label'] = kExpiredActionId;
  }
  return data;
}

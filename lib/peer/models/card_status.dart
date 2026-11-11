/// 主机对「这张卡还有效吗」的回答，以及卡片提交的回执。
///
/// 卡片身份是全局 `approval_id` / `interaction_id`，会话身份是帧上可选的
/// `channel_id`。打开会话时和轮询期间 App 用这些状态把失效卡移除、把
/// 已被别的设备答掉的卡标成已答。
class CardStatusEntry {
  const CardStatusEntry({required this.id, required this.state});

  final String id;
  final String state;

  bool get isAlive => state == 'alive';
  bool get isAnsweredElsewhere => state == 'answered_elsewhere';
  bool get isAnsweredHere => state == 'answered_here';

  /// 主机已经没有这张卡的等待位，且不是「被别的设备答了」：直接移除。
  bool get isGone =>
      state == 'gone' ||
      state == 'closed' ||
      state == 'cancelled' ||
      state == 'timeout';

  static CardStatusEntry fromJson(Map<dynamic, dynamic> json) =>
      CardStatusEntry(
        id: json['id']?.toString() ?? '',
        state: json['state']?.toString() ?? 'gone',
      );
}

/// `agent_card_resp_ack`：`ok=false` 时 App 不能把卡片标成已答。
class CardRespAck {
  const CardRespAck({
    required this.approvalId,
    required this.ok,
    required this.reason,
  });

  final String approvalId;
  final bool ok;
  final String reason;

  static CardRespAck fromJson(Map<String, dynamic> json) => CardRespAck(
        approvalId: json['approval_id']?.toString() ?? '',
        ok: json['ok'] == true,
        reason: json['reason']?.toString() ?? '',
      );
}

/// 主机明确拒收了这份答案（跨会话 / 卡片已失效 / 别人先答了）。
class PeerCardRejectedException implements Exception {
  const PeerCardRejectedException(this.reason);

  final String reason;

  @override
  String toString() {
    switch (reason) {
      case 'session_mismatch':
        return '这张卡片属于另一个会话，请回到发起它的会话再回答';
      case 'answered_elsewhere':
        return '这张卡片已在其他设备回答';
      case 'expired':
        return '这张卡片已失效';
      case 'answer_pending':
        return '回答暂时没有送达，请稍后重试';
      default:
        return '卡片提交失败（$reason）';
    }
  }
}

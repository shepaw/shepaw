/// 断连续传（turn resume）的纯逻辑工具。
///
/// 与 PeerAgentClientService 解耦，便于单元测试：
/// - [applyResumeDelta]：resume_resp 的增量去重（drop-prefix）；
/// - [evaluateTurnWatchdog]：turn 看门狗判定（suspended 冻结 / suspendCap / idle）。
library;

/// resume_resp 携带的 delta 是基于「发送 resume_req 时的基准长度 K」切出的。
/// 在 resp 到达前，新连接上可能已经有 live chunk 到达（重连即路由），这些
/// chunk 与 delta 前缀重叠。跳过 `receivedLength - baseLength` 个码元后，
/// 剩余部分才是真正缺失的内容 —— 重复 resume / live 重叠均天然幂等。
///
/// Dart 与 JS 的 String.length 同为 UTF-16 码元，与 hub 的 slice 偏移兼容。
String applyResumeDelta({
  required String delta,
  required int receivedLength,
  required int baseLength,
}) {
  var skip = receivedLength - baseLength;
  if (skip < 0) skip = 0;
  if (skip > delta.length) skip = delta.length;
  return delta.substring(skip);
}

/// turn 看门狗判定结果。
enum TurnWatchdogVerdict {
  /// 一切正常，继续等待。
  none,

  /// 无审批且非挂起状态下，超过 chatTimeout 未收到任何 agent 输出。
  idleTimeout,

  /// 挂起（断连等待重连续传）超过 suspendWaitHardCap。
  suspendCap,
}

/// turn 看门狗判定（纯函数）。
///
/// 规则（与 _awaitTurnCompletion 的语义一一对应）：
/// - 挂起中（suspendedSince != null）：idle 计时冻结（断连期间对端本来
///   就不会有帧到达），但受 suspendWaitHardCap 约束；
/// - 审批等待中（openApprovals > 0）：idle 计时冻结（用户读卡片的时间
///   不计入），且不设超时上限 —— 审批等多久由用户决定；
/// - 其余情况：距上次 agent 输出（或 turn 开始 / 审批结束）超过 chatTimeout
///   → idleTimeout。持续流式输出的健康长任务不受总时长限制。
TurnWatchdogVerdict evaluateTurnWatchdog({
  required DateTime now,
  required DateTime startedAt,
  required DateTime idleSince,
  required DateTime? suspendedSince,
  required int openApprovals,
  required Duration chatTimeout,
  required Duration suspendWaitHardCap,
}) {
  final suspended = suspendedSince;
  if (suspended != null) {
    if (now.difference(suspended) > suspendWaitHardCap) {
      return TurnWatchdogVerdict.suspendCap;
    }
    return TurnWatchdogVerdict.none;
  }
  if (openApprovals == 0 && now.difference(idleSince) > chatTimeout) {
    return TurnWatchdogVerdict.idleTimeout;
  }
  return TurnWatchdogVerdict.none;
}

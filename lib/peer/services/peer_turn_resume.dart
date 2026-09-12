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
/// - Hub 上游 ACP 重连中（upstreamReconnectingSince != null）：idle 计时
///   同样冻结 —— P2P 仍连着但 Hub↔Agent 可能在恢复，不应误判 30min 超时；
/// - 审批等待中（openApprovals > 0）：idle 计时冻结（用户读卡片的时间
///   不计入），且不设超时上限 —— 审批等多久由用户决定；
/// - 其余情况：距上次 agent 输出（或 turn 开始 / 审批结束）超过 chatTimeout
///   → idleTimeout。持续流式输出的健康长任务不受总时长限制。
TurnWatchdogVerdict evaluateTurnWatchdog({
  required DateTime now,
  required DateTime startedAt,
  required DateTime idleSince,
  required DateTime? suspendedSince,
  required DateTime? upstreamReconnectingSince,
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
  final upstreamReconnecting = upstreamReconnectingSince;
  if (upstreamReconnecting != null) {
    if (now.difference(upstreamReconnecting) > suspendWaitHardCap) {
      return TurnWatchdogVerdict.suspendCap;
    }
    return TurnWatchdogVerdict.none;
  }
  if (openApprovals == 0 && now.difference(idleSince) > chatTimeout) {
    return TurnWatchdogVerdict.idleTimeout;
  }
  return TurnWatchdogVerdict.none;
}

/// 已有助手正文且流静止后，视为回复结束（成功收口，不是超时失败）。
///
/// `agent_done` 只是便利信号，不是定义。工作流不应等成员/对端再吐一个
/// done；有正文、无在途审批、持续静默即结束。
const Duration kReplySettleIdle = Duration(seconds: 180);

/// 审批闸门卡住后，允许 stall probe 的最短等待。
///
/// 用户正在读卡片时不探测；但 `openApprovals` 因漏计 / 提交挂起而
/// 降不下来时，若一直跳过探测，群聊 Flow 会永远等这个成员。
const Duration kStaleApprovalProbeAfter = Duration(minutes: 10);

/// 是否应向 Hub 发 `agent_turn_resume_req` 探测停滞（连接仍存活、
/// 距上次输出超过 [stallProbeInterval]）。与断连后的 suspend-resume 不同：
/// 探测失败不会判死 turn，下一轮看门狗 tick 会重试。
///
/// 新鲜审批卡（[openApprovals] > 0 且距 [lastApprovalOpenedAt] 不足
/// [kStaleApprovalProbeAfter]）仍不探测，避免打断用户读卡。闸门过期后
/// 恢复探测，以便发现远端其实已经 `done`。
bool shouldProbeStalledTurn({
  required DateTime now,
  required DateTime idleSince,
  required DateTime? suspendedSince,
  required DateTime? upstreamReconnectingSince,
  required int openApprovals,
  required bool resumeInFlight,
  required DateTime? lastStallProbeAt,
  required Duration stallProbeInterval,
  DateTime? lastApprovalOpenedAt,
  Duration staleApprovalProbeAfter = kStaleApprovalProbeAfter,
}) {
  if (suspendedSince != null) return false;
  if (upstreamReconnectingSince != null) return false;
  if (openApprovals > 0) {
    final opened = lastApprovalOpenedAt;
    if (opened == null ||
        now.difference(opened) < staleApprovalProbeAfter) {
      return false;
    }
  }
  if (resumeInFlight) return false;
  if (now.difference(idleSince) < stallProbeInterval) return false;
  if (lastStallProbeAt != null &&
      now.difference(lastStallProbeAt) < stallProbeInterval) {
    return false;
  }
  return true;
}

/// 系统观察到回复已经结束：有助手正文、没有未决审批、流已静止。
///
/// 断连 / 上游重连期间不算结束（对端本来就不会再吐帧）。
bool shouldCompleteSettledReply({
  required DateTime now,
  required DateTime idleSince,
  required DateTime? suspendedSince,
  required DateTime? upstreamReconnectingSince,
  required int openApprovals,
  required bool hasAssistantContent,
  Duration settleIdle = kReplySettleIdle,
}) {
  if (!hasAssistantContent) return false;
  if (openApprovals > 0) return false;
  if (suspendedSince != null) return false;
  if (upstreamReconnectingSince != null) return false;
  return now.difference(idleSince) >= settleIdle;
}

/// One role/content line from a remote peer transcript.
class RemoteHistoryLine {
  const RemoteHistoryLine({required this.role, required this.content});

  final String role;
  final String content;
}

/// Last non-empty assistant (non-user) line, or null.
String? lastAssistantContentFromHistory(
  Iterable<RemoteHistoryLine> history,
) {
  for (final m in history.toList().reversed) {
    if (m.role != 'user' && m.content.trim().isNotEmpty) {
      return m.content;
    }
  }
  return null;
}

/// Group/workflow peer turns stream on the group [channelId] but persist
/// history on the member/workflow [sessionId]. If that session's remote
/// transcript already has a final assistant reply, a missed `agent_done`
/// must not keep the whole stage blocked.
bool remoteTranscriptUnblocksInflight({
  required String inflightSessionId,
  required String syncedRemoteSessionId,
  required String? lastAssistantContent,
}) {
  if (inflightSessionId.isEmpty || syncedRemoteSessionId.isEmpty) {
    return false;
  }
  if (lastAssistantContent == null || lastAssistantContent.trim().isEmpty) {
    return false;
  }
  return inflightSessionId == syncedRemoteSessionId;
}

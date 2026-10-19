import '../../models/remote_agent.dart';

/// Hub Agent 在这台 App 上的行 id，就是 Hub 上的那一个 id。
String peerAgentLocalId(String peerId, String remoteAgentId) => remoteAgentId;

/// [rowId] 是否是「来自 [peerId] 的 [remoteAgentId]」这一行在本机的 id。
///
/// 两种形态都要认：现在落库用 Hub id 本身（[peerAgentLocalId]），但旧版一律
/// 用 `peeragent_<peer>_<remote>`，而存量行没有迁移（`decidePeerAgentRowId`
/// 被删时只改了新行的落库规则）。只认一种会让老行上的孤儿审批卡永远匹配不上。
bool isPeerAgentRowId(String? rowId, String peerId, String remoteAgentId) =>
    rowId == remoteAgentId || rowId == 'peeragent_${peerId}_$remoteAgentId';

/// 该行是否已是「来自 [peerId] 的 remoteAgentId」对应的 peer agent。
bool isOwnedPeerAgentRow(
  RemoteAgent agent,
  String peerId,
  String remoteAgentId,
) {
  if (agent.protocol != ProtocolType.peer) return false;
  if (agent.sourcePeerId != peerId) return false;
  final rid = agent.remoteAgentId;
  return rid == null || rid == remoteAgentId;
}

/// 孤儿卡帧里的会话归属是否就是 [hostSessionId]。
///
/// 帧里的 `channel_id` 与 `hostSessionIdForChannel(currentChannelId)` 是同一
/// 口径（App 频道 id 去掉 `psess_`）。没有归属的旧帧一律不认领 —— 卡已经
/// 由服务层登记到全局提醒，不能再落进恰好打开着的会话。
bool orphanCardBelongsToHostSession(
  String? frameChannelId,
  String? hostSessionId,
) {
  final frame = frameChannelId?.trim() ?? '';
  return frame.isNotEmpty && frame == (hostSessionId?.trim() ?? '');
}

/// Match a hub orphan `agent_approval_req` to a group member peer agent.
///
/// Group chat Controllers do not set [ChatController.agentId] to the peer
/// member — orphan cards must be routed by peerId + remoteAgentId against
/// [groupAgents], otherwise approvals that race past `agent_done` are dropped.
RemoteAgent? matchGroupPeerAgent({
  required List<RemoteAgent> groupAgents,
  required String peerId,
  required String remoteAgentId,
}) {
  for (final agent in groupAgents) {
    if (!agent.isPeerAgent) continue;
    if (agent.sourcePeerId != peerId) continue;
    final rid = agent.remoteAgentId;
    if (rid != null && rid == remoteAgentId) return agent;
    if (agent.id == remoteAgentId) return agent;
  }
  return null;
}

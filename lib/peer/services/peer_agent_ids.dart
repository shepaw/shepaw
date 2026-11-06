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

/// 本机 agent 行 → Hub 侧认得的 agent id。
///
/// 新行落库时 id 就是 Hub id；旧行是 `peeragent_<peer>_<remote>`，必须先剥成
/// remote id，否则发给主机的 `task.agent` / 角色绑定会是一个不存在的值。
String hubAgentIdOf(RemoteAgent agent) {
  if (!agent.isPeerAgent) return agent.id;
  final remote = agent.remoteAgentId;
  if (remote != null && remote.isNotEmpty) {
    return hubAgentIdFromRaw(remote, peerId: agent.sourcePeerId ?? '');
  }
  return hubAgentIdFromRaw(agent.id, peerId: agent.sourcePeerId ?? '');
}

/// 任意来源的 agent 标识 → Hub 侧 agent id。
///
/// 数据里可能混着几种历史格式：本机行 id（老行是
/// `peeragent_<peer>_<remote>`）、带 `agent:` 前缀的引用、以及已经是 Hub id
/// 的裸值。运行页 / 设计页 / 检查器都要用同一套归一化，否则同一个 agent
/// 在不同入口会被翻译成不同的值。
String hubAgentIdFromRaw(String raw, {String peerId = ''}) {
  var id = raw.trim();
  if (id.startsWith('agent:')) id = id.substring('agent:'.length);
  final peer = peerId.trim();
  if (peer.isNotEmpty) {
    final prefix = 'peeragent_${peer}_';
    if (id.startsWith(prefix)) id = id.substring(prefix.length);
  }
  return id;
}

/// 孤儿卡帧里的会话归属是否就是 [hostSessionId]。
///
/// 帧里的 `channel_id` 与 `hostSessionIdForChannel(currentChannelId)` 是同一
/// 口径（App 频道 id 去掉 `psess_`）。没有归属的旧帧这里一律不匹配 ——
/// 它们由服务层落到 agent 普通单聊，聊天页按「单聊 + 同一 agent」单独认领，
/// 不能靠这个函数匹配任意打开的会话。
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

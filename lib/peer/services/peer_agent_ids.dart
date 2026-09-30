import '../../models/remote_agent.dart';

/// Hub Agent 在这台 App 上的行 id，就是 Hub 上的那一个 id。
String peerAgentLocalId(String peerId, String remoteAgentId) => remoteAgentId;

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

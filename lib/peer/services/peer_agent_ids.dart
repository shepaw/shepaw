import '../../models/remote_agent.dart';
import '../../services/she_service.dart';

/// peer-agent 在本地 `agents` 表中的「首选」id（Hub UUID）。
///
/// 仅当该 id 未被本机 agent（如惜宝固定 id）占用、且无旧版 namespaced 行时，
/// 才可作为落库主键；冲突时必须用 [legacyPeerAgentLocalId]。见 [decidePeerAgentRowId]。
String peerAgentLocalId(String peerId, String remoteAgentId) => remoteAgentId;

/// 命名空间化的本地 id（`peeragent_<peer>_<remote>`）。
///
/// 旧版一律用此格式；当 Hub UUID 与本机 agent id 冲突（惜宝
/// [SheService.sheId]）时仍必须使用，避免覆写本机行。
String legacyPeerAgentLocalId(String peerId, String remoteAgentId) =>
    'peeragent_${peerId}_$remoteAgentId';

/// 不可被 peer 注入覆写的本机固定 agent id。
bool isReservedLocalAgentId(String agentId) => agentId == SheService.sheId;

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
  final preferred = peerAgentLocalId(peerId, remoteAgentId);
  final legacy = legacyPeerAgentLocalId(peerId, remoteAgentId);
  for (final agent in groupAgents) {
    if (!agent.isPeerAgent) continue;
    if (agent.sourcePeerId != peerId) continue;
    final rid = agent.remoteAgentId;
    if (rid != null && rid == remoteAgentId) return agent;
    if (agent.id == preferred || agent.id == legacy) return agent;
  }
  return null;
}

/// Pure decision for which local `agents.id` to use for a hub remote agent.
///
/// Priority:
/// 1. Existing legacy `peeragent_*` row (stable across upgrades / collisions)
/// 2. Existing Hub-UUID row **only if** it already belongs to this peer agent
///    and is not a reserved local id (惜宝)
/// 3. Otherwise Hub UUID, unless reserved or colliding → legacy namespaced id
String decidePeerAgentRowId({
  required String peerId,
  required String remoteAgentId,
  RemoteAgent? existingByRemoteId,
  RemoteAgent? existingByLegacyId,
}) {
  final legacy = legacyPeerAgentLocalId(peerId, remoteAgentId);
  if (existingByLegacyId != null) return legacy;

  if (existingByRemoteId != null) {
    // Never treat reserved local ids (惜宝) as reusable peer primary keys,
    // even if a buggy sync already stamped peer metadata onto that row.
    if (isReservedLocalAgentId(existingByRemoteId.id) ||
        isReservedLocalAgentId(remoteAgentId)) {
      return legacy;
    }
    if (isOwnedPeerAgentRow(existingByRemoteId, peerId, remoteAgentId)) {
      return remoteAgentId;
    }
    // Collision with a local agent / another peer / unrelated row.
    return legacy;
  }

  if (isReservedLocalAgentId(remoteAgentId)) return legacy;
  return remoteAgentId;
}

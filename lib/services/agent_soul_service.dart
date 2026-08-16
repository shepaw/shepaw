import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import 'cognition_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';

/// Unified read/write for agent Soul (persona / system identity).
///
/// **权威**：本机 / 外接 ACP → 储物袋 `cognition/<agentId>/soul.md`（本机 device）。
/// Peer → 对端宿主同路径，经 `agent_soul_*` 中继；本机不落库。
///
/// `agents.metadata['system_prompt']` 仅作一次性迁移源，读写后清除。
class AgentSoulService {
  AgentSoulService._();
  static final AgentSoulService instance = AgentSoulService._();

  static const _tag = 'AgentSoul';
  final _log = LoggerService();

  /// 本机落盘 soul.md（含外接 ACP）；peer 走中继。
  bool usesSoulFile(RemoteAgent agent) => !agent.isPeerAgent;

  /// Read soul text for display / prompt building.
  Future<String> getSoul(RemoteAgent agent) async {
    if (agent.isPeerAgent) {
      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      if (peerId == null || remoteId == null) return '';
      if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
        return '';
      }
      final text = await PeerAgentClientService.instance.fetchSoul(
        peerId: peerId,
        remoteAgentId: remoteId,
      );
      return text ?? '';
    }

    await migrateLegacySystemPromptIfNeeded(agent);
    return (await CognitionService.instance.getAgentSoul(agent.id))?.trim() ??
        '';
  }

  /// Persist soul. Returns false when peer edit is denied or relay fails.
  Future<bool> updateSoul(RemoteAgent agent, String soul) async {
    final trimmed = soul.trim();

    if (agent.isPeerAgent) {
      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      if (peerId == null || remoteId == null) return false;
      return PeerAgentClientService.instance.setSoul(
        peerId: peerId,
        remoteAgentId: remoteId,
        soul: trimmed,
      );
    }

    await CognitionService.instance.updateAgentSoul(agent.id, trimmed);
    await _clearLegacySystemPrompt(agent.id);
    return true;
  }

  /// Whether a paired device may edit this local agent's soul.
  bool peerMayEditSoul(RemoteAgent agent) =>
      agent.peerBoundaryConfig.allowPeerSoulEdit;

  String _legacyPrompt(RemoteAgent agent) =>
      agent.metadata['system_prompt'] as String? ?? '';

  Future<String> _legacyPromptFromDb(RemoteAgent agent) async {
    try {
      final row = await LocalDatabaseService().getRemoteAgentById(agent.id);
      if (row != null) return _legacyPrompt(row);
    } catch (e) {
      _log.warning('read legacy system_prompt failed: $e', tag: _tag);
    }
    return _legacyPrompt(agent);
  }

  Future<void> _clearLegacySystemPrompt(String agentId) async {
    try {
      final db = LocalDatabaseService();
      final row = await db.getRemoteAgentById(agentId);
      if (row == null) return;
      final metadata = Map<String, dynamic>.from(row.metadata);
      if (!metadata.containsKey('system_prompt')) return;
      metadata.remove('system_prompt');
      await db.updateRemoteAgent(row.copyWith(metadata: metadata));
    } catch (e) {
      _log.warning('clear legacy system_prompt failed: $e', tag: _tag);
    }
  }

  /// One-time: seed `soul.md` from legacy `metadata.system_prompt`, then clear DB.
  Future<void> migrateLegacySystemPromptIfNeeded(RemoteAgent agent) async {
    if (agent.isPeerAgent) return;
    final current =
        (await CognitionService.instance.getAgentSoul(agent.id))?.trim() ?? '';
    if (current.isNotEmpty) {
      // File already authoritative — still scrub leftover metadata.
      await _clearLegacySystemPrompt(agent.id);
      return;
    }
    final legacy = (await _legacyPromptFromDb(agent)).trim();
    if (legacy.isEmpty) return;
    await CognitionService.instance.updateAgentSoul(agent.id, legacy);
    await _clearLegacySystemPrompt(agent.id);
    _log.info('Migrated system_prompt → soul.md for agent=${agent.id}',
        tag: _tag);
  }
}

import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import 'cognition_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';

/// Unified read/write for agent Soul (persona / system identity).
///
/// Local agents persist to `memory/<agent>/soul.md` via [CognitionService].
/// Remote ACP agents keep soul in `metadata['system_prompt']` (legacy key).
/// Peer agents relay get/set to the host when allowed.
class AgentSoulService {
  AgentSoulService._();
  static final AgentSoulService instance = AgentSoulService._();

  static const _tag = 'AgentSoul';
  final _log = LoggerService();

  /// Whether soul is stored on-device (memory file) vs metadata-only.
  bool usesSoulFile(RemoteAgent agent) =>
      agent.isLocal || agent.metadata['is_she'] == true;

  /// Read soul text for display / prompt building.
  Future<String> getSoul(RemoteAgent agent) async {
    if (agent.isPeerAgent) {
      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      if (peerId == null || remoteId == null) return _legacyPrompt(agent);
      if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
        return _legacyPrompt(agent);
      }
      final text = await PeerAgentClientService.instance.fetchSoul(
        peerId: peerId,
        remoteAgentId: remoteId,
      );
      return text ?? _legacyPrompt(agent);
    }

    if (usesSoulFile(agent)) {
      final soul =
          (await CognitionService.instance.getAgentSoul(agent.id)) ?? '';
      if (soul.trim().isNotEmpty) return soul;
      return _legacyPrompt(agent);
    }

    return _legacyPrompt(agent);
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

    if (usesSoulFile(agent)) {
      if (trimmed.isEmpty) {
        await CognitionService.instance.updateAgentSoul(agent.id, '');
      } else {
        await CognitionService.instance.updateAgentSoul(agent.id, trimmed);
      }
      await _clearLegacySystemPrompt(agent.id);
      return true;
    }

    await _saveLegacySystemPrompt(agent.id, trimmed);
    return true;
  }

  /// Whether a paired device may edit this local agent's soul.
  bool peerMayEditSoul(RemoteAgent agent) =>
      agent.peerBoundaryConfig.allowPeerSoulEdit;

  String _legacyPrompt(RemoteAgent agent) =>
      agent.metadata['system_prompt'] as String? ?? '';

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

  Future<void> _saveLegacySystemPrompt(String agentId, String soul) async {
    try {
      final db = LocalDatabaseService();
      final row = await db.getRemoteAgentById(agentId);
      if (row == null) return;
      final metadata = Map<String, dynamic>.from(row.metadata);
      if (soul.isEmpty) {
        metadata.remove('system_prompt');
      } else {
        metadata['system_prompt'] = soul;
      }
      await db.updateRemoteAgent(row.copyWith(metadata: metadata));
    } catch (e) {
      _log.warning('save legacy system_prompt failed: $e', tag: _tag);
    }
  }

  /// One-time migration: seed soul file from legacy metadata when empty.
  Future<void> migrateLegacySystemPromptIfNeeded(RemoteAgent agent) async {
    if (!usesSoulFile(agent) || agent.isShe) return;
    final legacy = _legacyPrompt(agent).trim();
    if (legacy.isEmpty) return;
    final current =
        (await CognitionService.instance.getAgentSoul(agent.id))?.trim() ?? '';
    if (current.isNotEmpty) return;
    await CognitionService.instance.updateAgentSoul(agent.id, legacy);
    await _clearLegacySystemPrompt(agent.id);
    _log.info('Migrated system_prompt → soul for agent=${agent.id}', tag: _tag);
  }
}

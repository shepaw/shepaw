import '../models/remote_agent.dart';
import '../peer/services/peer_agent_client_service.dart';
import '../peer/services/peer_connection_manager.dart';
import 'local_resume_generator.dart';
import 'logger_service.dart';
import 'remote_agent_service.dart';
import '../service_locator.dart';

/// Result of loading a resume for the edit screen.
class AgentResumeView {
  final String resume;
  final bool editable;
  /// 非空表示加载失败 / 离线等错误（页面据此展示错误态与重试）。
  final String? error;

  const AgentResumeView({
    required this.resume,
    required this.editable,
    this.error,
  });
}

/// Unified read/write for agent 简历（`RemoteAgent.bio`）。
///
/// 本机 / 外接 ACP → 本机 `agents.bio`（[RemoteAgentService.updateAgent]）。
/// Peer → 对端宿主持有，经 `agent_resume_*` 中继读写，本机仅同步副本。
class AgentResumeService {
  AgentResumeService._();
  static final AgentResumeService instance = AgentResumeService._();

  static const _tag = 'AgentResume';
  final _log = LoggerService();

  /// Load resume for display / edit. 永不抛错，错误放入 [AgentResumeView.error]。
  Future<AgentResumeView> load(RemoteAgent agent) async {
    if (!agent.isPeerAgent) {
      return AgentResumeView(resume: agent.bio ?? '', editable: true);
    }
    final peerId = agent.sourcePeerId;
    final remoteId = agent.remoteAgentId;
    if (peerId == null || remoteId == null) {
      return AgentResumeView(resume: agent.bio ?? '', editable: false);
    }
    if (!PeerConnectionManager.instance.connectedPeerIds.contains(peerId)) {
      // 离线时回退本地同步副本（只读），不让用户白跑一趟。
      return AgentResumeView(
        resume: agent.bio ?? '',
        editable: false,
        error: 'offline',
      );
    }
    try {
      final info = await PeerAgentClientService.instance
          .getResumeInfo(peerId: peerId, remoteAgentId: remoteId);
      if (info == null) {
        return AgentResumeView(
          resume: agent.bio ?? '',
          editable: false,
          error: 'offline',
        );
      }
      if (!info.isOk) {
        return AgentResumeView(
          resume: agent.bio ?? '',
          editable: false,
          error: info.error,
        );
      }
      return AgentResumeView(resume: info.resume, editable: info.editable);
    } catch (e) {
      _log.warning('load resume failed: $e', tag: _tag);
      return AgentResumeView(
        resume: agent.bio ?? '',
        editable: false,
        error: e.toString(),
      );
    }
  }

  /// Persist resume. Returns the persisted text; throws on failure.
  ///
  /// 清空简历要传空串（`copyWith(bio: null)` 无法清空）。
  Future<String> save(RemoteAgent agent, String text) async {
    final trimmed = text.trim();
    if (agent.isPeerAgent) {
      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      if (peerId == null || remoteId == null) {
        throw StateError('resume_save_no_peer');
      }
      final ok = await PeerAgentClientService.instance.setResume(
        peerId: peerId,
        remoteAgentId: remoteId,
        resume: trimmed,
      );
      if (!ok) throw StateError('resume_save_denied');
      return trimmed;
    }
    await getIt<RemoteAgentService>()
        .updateAgent(agent.copyWith(bio: trimmed));
    return trimmed;
  }

  /// Prompt-driven regeneration. Returns the new resume text（尚未经 [save]，
  /// 但 ACP 路径在网关侧已落库）。Throws on failure.
  Future<String> regenerate(
    RemoteAgent agent, {
    required String prompt,
  }) async {
    if (prompt.trim().isEmpty) {
      throw ArgumentError('prompt is required for resume regeneration');
    }
    if (agent.isPeerAgent) {
      final peerId = agent.sourcePeerId;
      final remoteId = agent.remoteAgentId;
      if (peerId == null || remoteId == null) {
        throw StateError('resume_rebuild_no_peer');
      }
      return PeerAgentClientService.instance.rebuildResumeViaPeer(
        peerId: peerId,
        remoteAgentId: remoteId,
        prompt: prompt.trim(),
      );
    }
    if (agent.isLocal) {
      return LocalResumeGenerator.regenerate(agent, prompt: prompt.trim())
          .timeout(const Duration(seconds: 90));
    }
    return getIt<RemoteAgentService>()
        .regenerateResume(agent.id, prompt: prompt.trim());
  }
}

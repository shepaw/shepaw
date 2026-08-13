import 'services/peer_agent_client_service.dart';

/// Per-engine native session modes, matching Hub `engine-modes.ts`.
///
/// Used when ACP has not advertised a live list yet so the App picker is not
/// stuck on "unsupported" for Cursor / Claude Code / Codex / OpenCode.
class EngineSessionModeCatalog {
  final List<PeerAgentMode> modes;
  final String? defaultModeId;

  const EngineSessionModeCatalog({
    required this.modes,
    this.defaultModeId,
  });
}

const _kEmptyCatalog = EngineSessionModeCatalog(modes: []);

final Map<String, EngineSessionModeCatalog> _kByEngine = {
  'cursor': EngineSessionModeCatalog(
    defaultModeId: 'agent',
    modes: [
      PeerAgentMode(value: 'agent', displayName: 'Agent', description: '完整工具权限，必要时询问'),
      PeerAgentMode(value: 'plan', displayName: 'Plan', description: '只规划，不改代码'),
      PeerAgentMode(value: 'ask', displayName: 'Ask', description: '只问答，只读'),
    ],
  ),
  'claude-code': EngineSessionModeCatalog(
    defaultModeId: 'acceptEdits',
    modes: [
      PeerAgentMode(value: 'default', displayName: 'Default', description: '读取自动放行，写入和命令需确认'),
      PeerAgentMode(value: 'acceptEdits', displayName: 'Accept Edits', description: '自动接受文件编辑，命令仍需确认'),
      PeerAgentMode(value: 'plan', displayName: 'Plan', description: '只规划，不改代码'),
      PeerAgentMode(value: 'auto', displayName: 'Auto', description: '后台安全检查后自动执行'),
      PeerAgentMode(value: "dontAsk", displayName: "Don't Ask", description: '只运行预先批准的工具，其余拒绝'),
      PeerAgentMode(value: 'bypassPermissions', displayName: 'Bypass Permissions', description: '跳过几乎所有确认（仅隔离环境）'),
    ],
  ),
  'codex': EngineSessionModeCatalog(
    defaultModeId: 'on-request',
    modes: [
      PeerAgentMode(value: 'untrusted', displayName: 'Untrusted', description: '仅放行受信任命令，其余询问'),
      PeerAgentMode(value: 'on-request', displayName: 'On request', description: '运行命令前询问'),
      PeerAgentMode(value: 'on-failure', displayName: 'On failure', description: '失败时再询问，成功则自动继续'),
      PeerAgentMode(value: 'never', displayName: 'Never', description: '不再询问审批'),
    ],
  ),
  'opencode': EngineSessionModeCatalog(
    defaultModeId: 'build',
    modes: [
      PeerAgentMode(value: 'build', displayName: 'Build', description: '完整开发工具'),
      PeerAgentMode(value: 'plan', displayName: 'Plan', description: '只规划，不改代码'),
    ],
  ),
};

EngineSessionModeCatalog engineSessionModeCatalog(String? engineId) {
  if (engineId == null || engineId.isEmpty) return _kEmptyCatalog;
  return _kByEngine[engineId] ?? _kEmptyCatalog;
}

/// Catalog converted to a picker list, with [current] defaulted when omitted.
PeerModesList catalogModesList(String? engineId, {String? current}) {
  final catalog = engineSessionModeCatalog(engineId);
  if (catalog.modes.isEmpty) return const PeerModesList(modes: []);
  final resolved = current != null &&
          current.isNotEmpty &&
          catalog.modes.any((m) => m.value == current)
      ? current
      : catalog.defaultModeId;
  return PeerModesList(modes: catalog.modes, current: resolved);
}

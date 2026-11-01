import '../../models/agent_node.dart';
import '../../models/remote_agent.dart';
import '../../services/she_service.dart';

/// 详情页 / 编辑页面对的三类 agent（见 .ai_workspace/AGENT_DETAIL_EDIT_REDESIGN.md §2）。
///
/// App 里已经没有「本机跑 LLM 的 agent」，惜宝也在主机端，所以所有行都是
/// `ProtocolType.peer`。剩下的差别只在主机是否允许这台 App 改它。
enum AgentDetailKind {
  /// 主机上的惜宝。不可改名、不可换头像、不可移除。
  she,

  /// 主机上的引擎实例（Claude Code / Codex …）：可改名、改工作区、移除。
  manageable,

  /// 兜底：主机上报但不可管理的 agent，以及残留的非 peer 行。只读。
  readOnly,
}

AgentDetailKind agentDetailKindOf(RemoteAgent agent) {
  if (agent.isPeerAgent &&
      (agent.isShe ||
          agent.id == SheService.sheId ||
          agent.remoteAgentId == SheService.sheId)) {
    return AgentDetailKind.she;
  }
  if (agent.isPeerAgent && agent.peerAgentManageable) {
    return AgentDetailKind.manageable;
  }
  return AgentDetailKind.readOnly;
}

/// 详情页顶部那颗状态徽标要表达的状态，按 §4.2 的优先级合成。
enum AgentDetailStatus {
  /// 来源主机没连上。
  hostOffline,

  /// 主机连着，但 agent 所在的工作节点离线。
  nodeOffline,

  /// 实例被主机禁用。
  disabled,

  /// 实例没在运行。
  stopped,

  /// 实例运行中。
  running,

  /// 其余（惜宝、不可管理 agent）：随主机在线。
  online,
}

AgentDetailStatus agentDetailStatusOf({
  required RemoteAgent agent,
  required bool hostConnected,
}) {
  if (!hostConnected) return AgentDetailStatus.hostOffline;
  final node = AgentNodeInfo.of(agent);
  if (!node.online) return AgentDetailStatus.nodeOffline;
  if (agentDetailKindOf(agent) == AgentDetailKind.manageable) {
    if (agent.metadata['enabled'] == false) return AgentDetailStatus.disabled;
    if (agent.metadata['running'] != true) return AgentDetailStatus.stopped;
    return AgentDetailStatus.running;
  }
  return AgentDetailStatus.online;
}

/// 按类别回答页面上每个字段该不该出现 / 能不能改（§3 字段矩阵的代码版）。
class AgentDetailCapabilities {
  const AgentDetailCapabilities._(this.kind);

  final AgentDetailKind kind;

  factory AgentDetailCapabilities.of(RemoteAgent agent) =>
      AgentDetailCapabilities._(agentDetailKindOf(agent));

  bool get isShe => kind == AgentDetailKind.she;
  bool get isManageable => kind == AgentDetailKind.manageable;

  /// 头像只覆盖本机显示。惜宝启动时会被改回默认图，改了也没用。
  bool get canEditAvatar => !isShe;

  /// 名称由主机提供。只有可管理实例的改名写得回主机。
  bool get canEditName => isManageable;

  /// 工作区（主 + 附加）在主机上，只有可管理实例能改。
  bool get canEditWorkspace => isManageable;

  /// 工作区卡片（只读展示）对惜宝没有意义。
  bool get showWorkspace => !isShe;

  /// 模式与客户端会话同步。惜宝没有这两项。
  bool get showModeAndSync => !isShe;

  /// 危险操作区：惜宝不可移除也不可隐藏。
  bool get showDangerZone => !isShe;

  /// 从主机移除（可管理实例）还是仅在本机隐藏（其余）。
  bool get removesFromHost => isManageable;
}

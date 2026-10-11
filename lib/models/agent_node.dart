import 'remote_agent.dart';

/// 主机名单里 Agent 所在的节点。`nodeId` 为空表示跑在主机上。
class AgentNodeInfo {
  const AgentNodeInfo({
    this.nodeId,
    this.nodeName,
    this.nodeRole,
    this.online = true,
  });

  /// 工作节点指纹；主机上的 Agent 没有。
  final String? nodeId;
  final String? nodeName;

  /// `host` / `worker`，旧主机不带。
  final String? nodeRole;

  /// 节点在线。主机上的 Agent 恒为 true。
  final bool online;

  bool get onWorker => nodeId != null || nodeRole == 'worker';

  factory AgentNodeInfo.fromAgentListEntry(Map<dynamic, dynamic> raw) =>
      AgentNodeInfo(
        nodeId: _text(raw['node_id']),
        nodeName: _text(raw['node_name']),
        nodeRole: _text(raw['node_role']),
        online: raw['online'] != false,
      );

  factory AgentNodeInfo.fromMetadata(Map<String, dynamic>? metadata) =>
      metadata == null
          ? const AgentNodeInfo()
          : AgentNodeInfo.fromAgentListEntry(metadata);

  factory AgentNodeInfo.of(RemoteAgent agent) =>
      AgentNodeInfo.fromMetadata(agent.metadata);

  Map<String, dynamic> toMetadata() => {
        if (nodeId != null) 'node_id': nodeId,
        if (nodeName != null) 'node_name': nodeName,
        if (nodeRole != null) 'node_role': nodeRole,
        'online': online,
      };
}

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

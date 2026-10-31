import '../local_database_service.dart';

/// 折叠组要问的主机与主机上的 Agent。
typedef FoldedTarget = ({String peerId, String remoteAgentId});

/// 按本机会话列表所在的 Agent 反查它挂在哪个主机上。
///
/// 本机 Agent（没配对过的）、群聊模式、查不到时返回空 —— 折叠组只在主机上的
/// Agent 才有，那时不画折叠组、也不问主机搜索。
Future<FoldedTarget?> resolveFoldedTarget({
  required String? agentId,
  required bool isGroupMode,
  LocalDatabaseService? database,
}) async {
  final id = agentId;
  if (id == null || isGroupMode) return null;
  final agent =
      await (database ?? LocalDatabaseService()).getRemoteAgentById(id);
  final peerId = agent?.sourcePeerId;
  final remoteId = agent?.remoteAgentId;
  if (peerId == null || remoteId == null) return null;
  return (peerId: peerId, remoteAgentId: remoteId);
}

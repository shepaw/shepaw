import '../services/she_service.dart';

/// 会话列表里要不要画设备名徽标。
///
/// 惜宝是这只袋子的身份，主机上的智能体也只有一台主机可指，两种都不画。
/// 工作设备上的智能体返回设备名。
String? agentSourceBadge({
  required String agentId,
  required Map<String, dynamic>? metadata,
  required String? hostPeerId,
}) {
  if (SheService.isSheIdentity(agentId, metadata)) return null;
  final sourceId = metadata?['source_peer_id'];
  if (sourceId is! String || sourceId.isEmpty) return null;
  final host = hostPeerId?.trim() ?? '';
  if (host.isNotEmpty && sourceId == host) return null;
  final name = metadata?['source_peer_name'];
  if (name is! String) return null;
  final trimmed = name.trim();
  return trimmed.isEmpty ? null : trimmed;
}

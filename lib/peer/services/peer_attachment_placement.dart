/// Peer 隧道附件落点：本机缓存与宿主权威共用同一条 `store://runtime/<host>/…`。
library;

import '../../models/remote_agent.dart';
import 'peer_agent_client_service.dart' show remoteSessionIdFromChannelId;
import 'peer_agent_host_service.dart' show peerAgentChannelId;
import 'peer_storage_service.dart';

/// 解析后的 peer 附件写入目标（device = 对端 fingerprint）。
class PeerAttachmentPlacement {
  const PeerAttachmentPlacement({
    required this.deviceId,
    required this.ownerId,
    required this.channelId,
  });

  /// 宿主（App2）device_id / Noise fingerprint。
  final String deviceId;

  /// 对端本地 agent id（[RemoteAgent.remoteAgentId]）。
  final String ownerId;

  /// 宿主入站 channel：`peer__{peerId}__{agentId}[__s_…]`。
  final String channelId;
}

/// 若 [agent] 为 peer 隧道且能解析配对指纹，返回与宿主一致的落点；否则 null。
Future<PeerAttachmentPlacement?> resolvePeerAttachmentPlacement({
  required RemoteAgent agent,
  required String localChannelId,
  PeerStorageService? peerStorage,
}) async {
  if (!agent.isPeerAgent) return null;
  final peerId = agent.sourcePeerId?.trim();
  final remoteId = agent.remoteAgentId?.trim();
  if (peerId == null ||
      peerId.isEmpty ||
      remoteId == null ||
      remoteId.isEmpty) {
    return null;
  }
  final peer = await (peerStorage ?? PeerStorageService()).getPeerById(peerId);
  final fp = peer?.fingerprint.trim() ?? '';
  if (fp.isEmpty) return null;

  final sessionId = remoteSessionIdFromChannelId(localChannelId) ??
      (localChannelId.isNotEmpty ? localChannelId : null);
  return PeerAttachmentPlacement(
    deviceId: fp,
    ownerId: remoteId,
    channelId: peerAgentChannelId(peerId, remoteId, sessionId),
  );
}

/// Host-side channel ids for turns forwarded from a paired device.
///
/// The Hub owns turn execution now; these helpers only identify the local
/// channel that an inbound peer attachment is placed in.
library;

/// 桌面 peer-agent 会话 channelId 前缀。用于标识本机作为 host 时、为来自配对
/// 设备的请求维护的独立入站会话。
const String kPeerAgentChannelPrefix = 'peer__';

/// 构造一个来源设备 + agent（+ 来源端会话）的入站会话 channelId。
///
/// [clientSessionId] 为来源设备上的会话标识：传入时，每个来源会话映射到独立的
/// host channel，从而让来源端「新开会话」在本机也得到一条干净、无历史的新会话；
/// 不传时回退到按「设备 + agent」聚合的旧 channel（兼容旧版客户端）。
String peerAgentChannelId(
  String peerId,
  String agentId, [
  String? clientSessionId,
]) {
  final base = '$kPeerAgentChannelPrefix${peerId}__$agentId';
  if (clientSessionId == null || clientSessionId.isEmpty) return base;
  // 清洗来源会话 id，避免空白/异常字符影响 channelId。
  final safe = clientSessionId.replaceAll(RegExp(r'\s+'), '_');
  return '${base}__s_$safe';
}

/// 判断某 channelId 是否为 peer-agent 隐藏会话。
bool isPeerAgentChannel(String? channelId) =>
    channelId != null && channelId.startsWith(kPeerAgentChannelPrefix);

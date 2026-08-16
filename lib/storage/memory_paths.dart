/// Agent 认知（Soul + 结构化记忆）在储物袋中的路径约定。
///
/// 权威 space：[StoreSpace.cognition]（旧 [StoreSpace.memory] 只读兼容）。
///
/// 本机 / 宿主自身：
/// `store://cognition/<device>/<agentId>/entries/<id>.json`
/// `store://cognition/<device>/<agentId>/soul.md`
///
/// 配对设备经 peer 中继写入的子记忆（按客户端 peerId 隔离）：
/// `store://cognition/<device>/<agentId>/peers/<peerId>/entries/<id>.json`
///
/// `runtime/<owner>/memory.md` 仍可作人读镜像（非权威）。
library;

import 'runtime_paths.dart';
import 'store_protocol.dart';

class MemoryPaths {
  MemoryPaths._();

  static String agentRoot(String agentId) =>
      RuntimePaths.sanitizeSegment(agentId);

  /// Peer 子记忆根目录。
  static String peerRoot(String agentId, String peerId) =>
      '${agentRoot(agentId)}/peers/${RuntimePaths.sanitizeSegment(peerId)}';

  /// [peerClientId] 非空时落到 peers 子树，否则为 agent 根。
  static String scopedRoot(String agentId, {String? peerClientId}) {
    final peer = peerClientId?.trim();
    if (peer == null || peer.isEmpty) return agentRoot(agentId);
    return peerRoot(agentId, peer);
  }

  static String metaJson(String agentId, {String? peerClientId}) =>
      '${scopedRoot(agentId, peerClientId: peerClientId)}/meta.json';

  static String entriesDir(String agentId, {String? peerClientId}) =>
      '${scopedRoot(agentId, peerClientId: peerClientId)}/entries';

  static String entryJson(
    String agentId,
    int memoryId, {
    String? peerClientId,
  }) =>
      '${entriesDir(agentId, peerClientId: peerClientId)}/$memoryId.json';

  /// Soul 权威正文（与 entries 并列，不按 peer 拆分）。
  static String soulMd(String agentId) => '${agentRoot(agentId)}/soul.md';

  static String uri({
    required String deviceId,
    required String relPath,
  }) =>
      storeUriWithRef(StoreSpace.cognition, deviceId, relPath);
}

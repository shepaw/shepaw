import '../peer/services/peer_storage_service.dart';
import '../services/logger_service.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 将某 agent/group 的 `runtime/<owner>/` 前缀分享给 owner 级配对设备（只读）。
///
/// 不整区开放 runtime；默认关闭，需显式调用。
class RuntimeShareService {
  RuntimeShareService._();
  static final RuntimeShareService instance = RuntimeShareService._();

  static const _tag = 'RuntimeShare';
  final _log = LoggerService();
  final _peerStorage = PeerStorageService();

  /// 分享 [ownerId] 运行时前缀给所有 trust=owner 的配对端。
  Future<int> shareOwnerRuntimeWithOwnerPeers(String ownerId) async {
    final prefix = RuntimePaths.runtimeRoot(ownerId);
    final peers = await _peerStorage.loadAllPeers();
    var n = 0;
    for (final peer in peers) {
      if (peer.trustLevel != TrustLevel.owner) continue;
      await _peerStorage.setStoreShare(
        peer.id,
        space: StoreSpace.runtime,
        path: prefix,
        shared: true,
      );
      await StoreService.instance.pushShareAnnounce(peer.id);
      n++;
    }
    _log.info('shared runtime/$prefix with $n owner peers', tag: _tag);
    return n;
  }

  /// 撤销 [ownerId] 在所有 owner peer 上的 runtime 前缀分享。
  Future<int> revokeOwnerRuntimeFromOwnerPeers(String ownerId) async {
    final prefix = RuntimePaths.runtimeRoot(ownerId);
    final peers = await _peerStorage.loadAllPeers();
    var n = 0;
    for (final peer in peers) {
      if (peer.trustLevel != TrustLevel.owner) continue;
      await _peerStorage.setStoreShare(
        peer.id,
        space: StoreSpace.runtime,
        path: prefix,
        shared: false,
      );
      await StoreService.instance.pushShareAnnounce(peer.id);
      n++;
    }
    _log.info('revoked runtime/$prefix from $n owner peers', tag: _tag);
    return n;
  }

  /// 当前对 [peerId] 已分享的 runtime 前缀列表。
  Future<List<String>> listedRuntimePrefixes(String peerId) async {
    final entries = await _peerStorage.getStoreShares(peerId);
    return [
      for (final e in entries)
        if (e.shared && e.space == StoreSpace.runtime && e.path.isNotEmpty)
          e.path,
    ];
  }
}

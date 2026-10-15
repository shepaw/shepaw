/// 「本机刚建、还没往主机发过东西」的会话集合。
///
/// 新建会话是纯本地的（[SessionService.createNewSession] 只往本机库插一条
/// channel 行），主机侧的会话要等第一条消息真正发出去时才懒建。所以在这之前
/// 回主机读这一页历史一定是白跑——外网代理下那是好几秒。
///
/// 判定不能用「本机没有这条 channel 行」：`generateChannelId` 那条确定性 id
/// 路径（旧版 DM id、深链进来）本机同样没有行，但主机那边可能有历史，跳过会
/// 丢消息。只有 [mark] 显式标过的 id 才享受跳过。
///
/// 标记是内存态，并且**有寿命**：
/// - 第一条消息落库即 [clear]（会话从此不再是新的）；
/// - 兜底 [ttl]：连点两次「新建会话」时前一条会被 prune，没人再来 clear 它，
///   不设上限的话这条陈旧标记会永久压掉后面那次真实的主机回读。
class FreshLocalChannelRegistry {
  FreshLocalChannelRegistry({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 64,
  });

  final Duration ttl;
  final int maxEntries;

  /// 用「标记时刻」当插入顺序；Dart 的 LinkedHashMap 保留插入序，
  /// 超容量时从最旧的开始丢。
  final _markedAt = <String, DateTime>{};

  /// 标记 [channelId] 是本机刚建的会话。
  void mark(String channelId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _markedAt.remove(channelId);
    _markedAt[channelId] = at;
    _evict(at);
  }

  /// [channelId] 是否还是「本机刚建、没发过」，且标记没过期。
  bool isFresh(String channelId, {DateTime? now}) {
    final at = _markedAt[channelId];
    if (at == null) return false;
    if ((now ?? DateTime.now()).difference(at) >= ttl) {
      _markedAt.remove(channelId);
      return false;
    }
    return true;
  }

  /// 会话已经有内容（或已作废）——不必再跳过主机回读。未标记的 id 是空操作。
  void clear(String channelId) {
    _markedAt.remove(channelId);
  }

  void _evict(DateTime now) {
    _markedAt.removeWhere((_, at) => now.difference(at) >= ttl);
    while (_markedAt.length > maxEntries) {
      _markedAt.remove(_markedAt.keys.first);
    }
  }
}

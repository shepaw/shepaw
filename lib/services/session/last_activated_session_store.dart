import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// 「对话入口」要回到用户最近一次亲手点开的那条会话。
///
/// 刻意不复用 `channels.updated_at`：那是会话活跃时间，主机同步会用真实活跃
/// 时间覆写，而且连着同一台主机的客户端要靠它排成同一份列表，本机「刚打开过」
/// 不能写进去（见 `chat_controller_load.dart` / `_openDrawerSession`）。这里只记
/// 本机人工点选的结果，跨重启保留，也不参与会话列表排序。
///
/// 每个 agent 一个 key：`agent:<id>`。群会话沿用 channels.updated_at 恢复最近
/// 打开，不走这份指针。
class LastActivatedSessionStore {
  LastActivatedSessionStore({this.prefs});

  /// 测试可直接注入 mock 过的 SharedPreferences；生产留空走插件单例。
  final SharedPreferences? prefs;

  static const String _keyPrefix = 'last_activated_session:';

  static String agentKey(String agentId) => 'agent:$agentId';

  /// 进程内立即生效的镜像。
  ///
  /// 所有写入点都是 `unawaited`（切换会话不能被平台通道拖住），而
  /// `touchChannelUpdatedAt` / 草稿 publish 会马上触发一轮会话列表补刷。只读
  /// 盘上的值，这轮补刷可能早于写盘完成，把入口又带回旧会话。remember 因此
  /// 同步写镜像，写盘时再取一次最新值：连续点选也不会因平台通道乱序把旧的
  /// 那条写回去。
  final Map<String, String> _volatile = <String, String>{};

  Future<SharedPreferences?> _prefs() async {
    if (prefs != null) return prefs;
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      // 平台通道没就绪（子窗口 / 测试）时不该拖垮会话列表刷新。
      return null;
    }
  }

  String _storageKey(String conversationKey) => '$_keyPrefix$conversationKey';

  /// 批量读，避免列表刷新时为每个 agent 单独等一次平台通道。
  Future<Map<String, String>> readAll(Iterable<String> conversationKeys) async {
    final store = await _prefs();
    final out = <String, String>{};
    for (final key in conversationKeys) {
      if (key.isEmpty) continue;
      final pending = _volatile[key];
      if (pending != null) {
        // 空串是 forgetChannel 立的墓碑：盘上的旧值还没删完时，这一轮
        // refresh 也不能把它读回去。
        if (pending.isNotEmpty) out[key] = pending;
        continue;
      }
      if (store == null) continue;
      try {
        final channelId = store.getString(_storageKey(key));
        if (channelId != null && channelId.isNotEmpty) {
          out[key] = channelId;
        }
      } catch (_) {
        // 单个 key 读坏不该拖垮整张列表。
      }
    }
    return out;
  }

  Future<String?> read(String conversationKey) async {
    if (conversationKey.isEmpty) return null;
    final values = await readAll([conversationKey]);
    return values[conversationKey];
  }

  Future<void> remember(String conversationKey, String channelId) async {
    if (conversationKey.isEmpty || channelId.isEmpty) return;
    // 同步生效：紧接着的 refresh 必须看到这次点选。
    _volatile[conversationKey] = channelId;
    final store = await _prefs();
    if (store == null) return;
    // 写盘时取最新值，两次快速点选不会让先发起的那次把旧会话写回去。
    final latest = _volatile[conversationKey];
    if (latest == null || latest.isEmpty) return;
    try {
      await store.setString(_storageKey(conversationKey), latest);
    } catch (_) {
      // 记不住只是丢掉「回到上次那条」的便利，不该影响切换会话本身。
    }
  }

  /// 会话被删掉时清掉指向它的指针，避免同 id 的会话后来又出现时串回去。
  Future<void> forgetChannel(String channelId) async {
    if (channelId.isEmpty) return;
    // 同步立墓碑：readAll 立刻不再返回这条会话，盘上的 remove 还在路上也
    // 不会被补刷读回去；在路上的 remember 也会因为取到空值而放弃写盘。
    for (final key in _volatile.keys.toList()) {
      if (_volatile[key] == channelId) _volatile[key] = '';
    }
    final store = await _prefs();
    if (store == null) return;
    try {
      final keys = store
          .getKeys()
          .where((key) =>
              key.startsWith(_keyPrefix) && store.getString(key) == channelId)
          .toList();
      final toRemove = <String>[];
      for (final key in keys) {
        final conversationKey = key.substring(_keyPrefix.length);
        final current = _volatile[conversationKey];
        // 期间又有人人工点开了新会话：别把新指针一起删掉。
        if (current != null && current != channelId && current.isNotEmpty) {
          continue;
        }
        _volatile[conversationKey] = '';
        toRemove.add(key);
      }
      // 必须等移除落地：调用方随后可能立刻刷新列表 / 退出进程。
      await Future.wait([for (final key in toRemove) store.remove(key)]);
    } catch (_) {}
  }
}

import '../models/channel.dart';

/// 把 Hub 群 JSON 收成客户端能存的 [Channel]。空字符串当成没填。
Channel channelFromHubGroup(Map<String, dynamic> json) {
  final copy = Map<String, dynamic>.from(json);
  final meta = copy['metadata'];
  if (meta is Map) {
    final next = Map<String, dynamic>.from(meta);
    for (final key in const [
      'description',
      'system_prompt',
      'avatar',
      'mention_mode',
    ]) {
      final value = next[key];
      if (value is String && value.trim().isEmpty) next.remove(key);
    }
    final rounds = next['max_loop_rounds'];
    if (rounds == null || rounds == 0) next.remove('max_loop_rounds');
    copy['metadata'] = next;
  }
  final topRounds = copy['max_loop_rounds'];
  if (topRounds == null || topRounds == 0) copy.remove('max_loop_rounds');
  return Channel.fromJson(copy);
}

/// 本地有、主机列表里没有的群 id。这些要从缓存删掉。
Set<String> staleGroupIds(
  Iterable<String> localIds,
  Iterable<Map<String, dynamic>> hubGroups,
) {
  final live = <String>{
    for (final group in hubGroups)
      if (group['id'] is String && (group['id'] as String).isNotEmpty)
        group['id'] as String,
  };
  return {
    for (final id in localIds)
      if (!live.contains(id)) id,
  };
}

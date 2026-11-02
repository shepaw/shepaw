import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一份没保存的草稿。
class FlowDraft {
  const FlowDraft({
    required this.yaml,
    required this.baseRevision,
    required this.savedMs,
  });

  final String yaml;

  /// 草稿是基于哪一版改的。库里已经更新到别的版本时，恢复前要先看差异。
  final int baseRevision;
  final int savedMs;
}

/// 未保存草稿的本地暂存（方案「关键设计 10」）。
///
/// 草稿太容易丢：列表里点另一行会换 `ValueKey`，编辑器直接销毁，`dispose` 都
/// 来不及 flush；群主回复后 `reload()` 会静默覆盖。这里每次改动后落一份，下次
/// 打开同一流程时问一句要不要恢复。
///
/// 只存 YAML 和版本号：挂起的字段改动已经混进 YAML 里了（主机的回包才是权威
/// 草稿），没发出去的那部分在关闭时会 flush 一次。
class FlowDraftStore {
  FlowDraftStore({SharedPreferences? prefs}) : _prefs = prefs;

  SharedPreferences? _prefs;

  static const _prefix = 'flow_draft_v1';

  Future<SharedPreferences> _store() async =>
      _prefs ??= await SharedPreferences.getInstance();

  String _key({
    required String peerId,
    required String scope,
    required String name,
  }) =>
      '$_prefix|$peerId|$scope|$name';

  Future<void> save({
    required String peerId,
    required String scope,
    required String name,
    required String yaml,
    required int baseRevision,
  }) async {
    final prefs = await _store();
    await prefs.setString(
      _key(peerId: peerId, scope: scope, name: name),
      jsonEncode({
        'yaml': yaml,
        'base_revision': baseRevision,
        'saved_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    );
  }

  Future<FlowDraft?> load({
    required String peerId,
    required String scope,
    required String name,
  }) async {
    final prefs = await _store();
    final raw = prefs.getString(_key(peerId: peerId, scope: scope, name: name));
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return FlowDraft(
        yaml: (map['yaml'] as String?) ?? '',
        baseRevision: (map['base_revision'] as num?)?.toInt() ?? 0,
        savedMs: (map['saved_ms'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      // 存坏了就当没有，别把人卡在恢复流程里。
      await clear(peerId: peerId, scope: scope, name: name);
      return null;
    }
  }

  Future<void> clear({
    required String peerId,
    required String scope,
    required String name,
  }) async {
    final prefs = await _store();
    await prefs.remove(_key(peerId: peerId, scope: scope, name: name));
  }
}

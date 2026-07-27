import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// master 侧设备游标账（docs/storage_protocol_spec.md §6.1）：
/// 每个设备目录已应用的游标 applied_seq。
/// 持久化于 `<store>/.system/device_cursors.json`。
class DeviceCursorStore {
  DeviceCursorStore({required Directory storeRoot})
      : _file = File(p.join(storeRoot.path, '.system', 'device_cursors.json'));

  final File _file;
  Map<String, int>? _cache;

  Future<Map<String, int>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    if (!await _file.exists()) return _cache = <String, int>{};
    try {
      final decoded = jsonDecode(await _file.readAsString()) as Map;
      return _cache =
          decoded.map((k, v) => MapEntry(k as String, (v as num).toInt()));
    } catch (_) {
      return _cache = <String, int>{};
    }
  }

  Future<int> appliedSeq(String deviceId) async => (await _load())[deviceId] ?? 0;

  /// 全表快照（M6：新 master 向旧 master 拉取各设备游标）。
  Future<Map<String, int>> all() async => Map<String, int>.of(await _load());

  /// 推进游标（只进不退）。返回推进后的值。
  Future<int> advance(String deviceId, int uptoSeq) async {
    final map = await _load();
    final current = map[deviceId] ?? 0;
    final next = uptoSeq > current ? uptoSeq : current;
    map[deviceId] = next;
    await _persist(map);
    return next;
  }

  /// 种子导入（只进不退合并）。返回合并后全表。
  Future<Map<String, int>> seed(Map<String, int> cursors) async {
    final map = await _load();
    for (final e in cursors.entries) {
      final current = map[e.key] ?? 0;
      if (e.value > current) map[e.key] = e.value;
    }
    await _persist(map);
    return Map<String, int>.of(map);
  }

  /// 删除某设备游标账（镜像目录被手动 purge 后）。
  Future<void> remove(String deviceId) async {
    final map = await _load();
    if (!map.containsKey(deviceId)) return;
    map.remove(deviceId);
    await _persist(map);
  }

  Future<void> _persist(Map<String, int> map) async {
    _cache = map;
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(map));
    await tmp.rename(_file.path);
  }
}

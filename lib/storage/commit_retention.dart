import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'gfs_retention.dart';
import 'local_store.dart';
import 'store_protocol.dart';

/// `commit.retention` 解析与执行（docs/storage_protocol_spec.md §2.6）。
///
/// 支持：
/// - `{ "policy": "keep_last", "keep": 4, "include_prefix"?: "reprotect-" }`
/// - `{ "policy": "gfs", "daily": 7, "weekly": 28, "monthly": 12,
///      "exclude_prefix"?: "reprotect-" }`
///
/// 作用域为某设备某分区下的**顶层目录**（快照 / 再保护包 id）；删除走
/// [LocalStore.delete]（进回收站，本机变更入 SyncJournal）。
class CommitRetention {
  CommitRetention._();

  /// 解析失败返回 null（忽略非法字段，不阻断 commit）。
  static CommitRetentionPolicy? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<String, dynamic>();
    final policy = map['policy'] as String?;
    if (policy == 'keep_last') {
      final keep = (map['keep'] as num?)?.toInt();
      if (keep == null || keep < 0) return null;
      return KeepLastRetention(
        keep: keep,
        includePrefix: map['include_prefix'] as String?,
        excludePrefix: map['exclude_prefix'] as String?,
      );
    }
    if (policy == 'gfs') {
      return GfsRetentionPolicy(
        daily: (map['daily'] as num?)?.toInt() ?? 7,
        weekly: (map['weekly'] as num?)?.toInt() ?? 28,
        monthly: (map['monthly'] as num?)?.toInt() ?? 12,
        includePrefix: map['include_prefix'] as String?,
        excludePrefix: map['exclude_prefix'] as String?,
      );
    }
    return null;
  }

  /// 执行策略；返回删除的顶层目录数。
  static Future<int> apply(
    LocalStore store, {
    required String deviceId,
    required String space,
    required CommitRetentionPolicy policy,
  }) async {
    if (!StoreSpace.isValid(space) || !isValidDeviceId(deviceId)) return 0;
    final entries = await _listTopLevel(store, deviceId, space);
    final filtered = entries.where((e) {
      if (policy.includePrefix != null &&
          !e.id.startsWith(policy.includePrefix!)) {
        return false;
      }
      if (policy.excludePrefix != null &&
          e.id.startsWith(policy.excludePrefix!)) {
        return false;
      }
      return true;
    }).toList();

    final toDelete = switch (policy) {
      KeepLastRetention(:final keep) => _selectKeepLast(filtered, keep),
      GfsRetentionPolicy(
        :final daily,
        :final weekly,
        :final monthly,
      ) =>
        selectGfs(
          [for (final e in filtered) (e.id, e.createdMs)],
          dailyWindow: daily,
          weeklyWindow: weekly,
          monthlyWindow: monthly,
        ).deleteIds.toList(),
    };

    var removed = 0;
    for (final id in toDelete) {
      try {
        await store.delete(deviceId, space, id);
        removed++;
      } catch (_) {
        // 已不存在或并发删除：忽略
      }
    }
    return removed;
  }
}

sealed class CommitRetentionPolicy {
  const CommitRetentionPolicy({this.includePrefix, this.excludePrefix});
  final String? includePrefix;
  final String? excludePrefix;

  Map<String, dynamic> toJson();
}

final class KeepLastRetention extends CommitRetentionPolicy {
  const KeepLastRetention({
    required this.keep,
    super.includePrefix,
    super.excludePrefix,
  });
  final int keep;

  @override
  Map<String, dynamic> toJson() => {
        'policy': 'keep_last',
        'keep': keep,
        if (includePrefix != null) 'include_prefix': includePrefix,
        if (excludePrefix != null) 'exclude_prefix': excludePrefix,
      };
}

final class GfsRetentionPolicy extends CommitRetentionPolicy {
  const GfsRetentionPolicy({
    this.daily = 7,
    this.weekly = 28,
    this.monthly = 12,
    super.includePrefix,
    super.excludePrefix,
  });
  final int daily;
  final int weekly;
  final int monthly;

  @override
  Map<String, dynamic> toJson() => {
        'policy': 'gfs',
        'daily': daily,
        'weekly': weekly,
        'monthly': monthly,
        if (includePrefix != null) 'include_prefix': includePrefix,
        if (excludePrefix != null) 'exclude_prefix': excludePrefix,
      };
}

class _TopEntry {
  _TopEntry(this.id, this.createdMs);
  final String id;

  /// 快照年龄基准：优先 manifest.created_at（逻辑创建时间，与
  /// [ScheduledSnapshotService.pruneGfs] 一致）；无 manifest 时回退目录 mtime。
  final int createdMs;
}

Future<List<_TopEntry>> _listTopLevel(
    LocalStore store, String deviceId, String space) async {
  final dir = Directory(p.join(store.root.path, deviceId, space));
  if (!await dir.exists()) return const [];
  final out = <_TopEntry>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final id = p.basename(entity.path);
    if (id.startsWith('.')) continue;
    // 目录 mtime 会被同步 / 再保护 / 恢复等操作触碰，不代表快照真实年龄。
    final logical = await _manifestCreatedAtMs(entity);
    final stat = await entity.stat();
    out.add(
        _TopEntry(id, logical ?? stat.modified.millisecondsSinceEpoch));
  }
  out.sort((a, b) => b.createdMs.compareTo(a.createdMs));
  return out;
}

/// 读取顶层目录内 manifest.json 的 `created_at`；不存在或不可读返回 null。
Future<int?> _manifestCreatedAtMs(Directory dir) async {
  try {
    final f = File(p.join(dir.path, 'manifest.json'));
    if (!await f.exists()) return null;
    final json = jsonDecode(await f.readAsString());
    if (json is Map && json['created_at'] is num) {
      return (json['created_at'] as num).toInt();
    }
  } catch (_) {
    // 回退由调用方处理
  }
  return null;
}

List<String> _selectKeepLast(List<_TopEntry> newestFirst, int keep) {
  if (keep < 0) keep = 0;
  if (newestFirst.length <= keep) return const [];
  return [for (final e in newestFirst.skip(keep)) e.id];
}

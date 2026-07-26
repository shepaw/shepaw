/// GFS（Grandfather-Father-Son）保留策略（docs/storage_space_plan.md §5.1
/// 决策 4）：保留最近 7 个日快照、4 个周快照、12 个月快照。
///
/// 窗口按【距现在的实际时间跨度】计算（经典 GFS）：稀疏快照不会把
/// 一年前的老快照算进"最近 12 个月"。纯函数，时间经参数注入以便测试。
library;

/// GFS 分桶后的保留/删除判定。
class GfsSelection {
  GfsSelection({required this.keepIds, required this.deleteIds});
  final Set<String> keepIds;
  final Set<String> deleteIds;
}

/// 选择要删除的快照 id。
///
/// [snapshots] 为 (id, createdAtMs) 列表；[nowMs] 注入当前时间。
/// 规则（同一快照可被多级命中，命中一级即保留）：
/// - 日级：距今 ≤ [dailyWindow] 天的日期内，每天最新一份；
/// - 周级：距今 ≤ [weeklyWindow] 天的 ISO 周内，每周最新一份；
/// - 月级：距今 < [monthlyWindow] 个自然月内，每月最新一份。
GfsSelection selectGfs(
  List<(String, int)> snapshots, {
  int dailyWindow = 7,
  int weeklyWindow = 28,
  int monthlyWindow = 12,
  int? nowMs,
}) {
  if (snapshots.isEmpty) {
    return GfsSelection(keepIds: const {}, deleteIds: const {});
  }
  final now = DateTime.fromMillisecondsSinceEpoch(
          nowMs ?? DateTime.now().millisecondsSinceEpoch)
      .toLocal();
  final sorted = snapshots.toList()
    ..sort((a, b) => b.$2.compareTo(a.$2)); // 新→旧

  final keep = <String>{};
  final seenDays = <String>{};
  final seenWeeks = <String>{};
  final seenMonths = <int>{};

  for (final (id, ms) in sorted) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    final dayKey = '${t.year}-${t.month}-${t.day}';
    final weekKey = '${_isoWeekYear(t)}-W${_isoWeek(t)}';
    final monthKey = t.year * 12 + t.month;

    final dayDiff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(t.year, t.month, t.day))
        .inDays;
    final weekStartDiff = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1))
        .difference(DateTime(t.year, t.month, t.day)
            .subtract(Duration(days: t.weekday - 1)))
        .inDays;
    final monthDiff = (now.year * 12 + now.month) - monthKey;

    // 日级：窗口内每天最新一份（降序遍历，首次见即最新）
    if (dayDiff <= dailyWindow && seenDays.add(dayKey)) keep.add(id);
    // 周级：窗口内每周最新一份
    if (weekStartDiff <= weeklyWindow && seenWeeks.add(weekKey)) keep.add(id);
    // 月级：窗口内每月最新一份
    if (monthDiff < monthlyWindow && seenMonths.add(monthKey)) keep.add(id);
  }

  return GfsSelection(
    keepIds: keep,
    deleteIds: {for (final (id, _) in sorted) id}..removeAll(keep),
  );
}

/// ISO-8601 周数（1..53）。
int _isoWeek(DateTime t) {
  final dayOfYear = t.difference(DateTime(t.year, 1, 1)).inDays + 1;
  final weekday = t.weekday; // Mon=1..Sun=7
  return ((dayOfYear - weekday + 10) / 7).floor();
}

/// ISO 周所属年（跨年周可能属于上一年/下一年）。
int _isoWeekYear(DateTime t) {
  final week = _isoWeek(t);
  if (week == 0) return t.year - 1;
  if (week >= 52 && t.month == 1) return t.year - 1;
  if (week == 1 && t.month == 12) return t.year + 1;
  return t.year;
}

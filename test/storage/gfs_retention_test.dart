import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/gfs_retention.dart';

/// GFS 保留策略（docs/storage_space_plan.md §5.1）：7 日/4 周/12 月。
void main() {
  int ms(DateTime t) => t.millisecondsSinceEpoch;

  group('selectGfs', () {
    test('7 个日快照：每天保留最新一份，超出删除', () {
      final now = DateTime(2026, 7, 26, 12, 0);
      // 10 天每天一份
      final snaps = [
        for (var i = 0; i < 10; i++)
          ('day-$i', ms(now.subtract(Duration(days: i)))),
      ];
      final sel = selectGfs(snaps, nowMs: ms(now));
      // 最近 7 个日历日保留（day-0..day-6）；day-7 起仅靠周/月级
      for (var i = 0; i < 7; i++) {
        expect(sel.keepIds, contains('day-$i'), reason: 'day-$i kept');
      }
    });

    test('日窗口边界：dayDiff==7 不计入日级（仅 0..6）', () {
      final now = DateTime(2026, 7, 26, 12, 0);
      // 关闭周/月窗口，隔离日级
      final snaps = [
        ('d0', ms(now)),
        ('d6', ms(now.subtract(const Duration(days: 6)))),
        ('d7', ms(now.subtract(const Duration(days: 7)))),
      ];
      final sel = selectGfs(snaps,
          nowMs: ms(now), weeklyWindow: 0, monthlyWindow: 0);
      expect(sel.keepIds, containsAll(['d0', 'd6']));
      expect(sel.deleteIds, contains('d7'));
    });

    test('同日多份只留最新', () {
      final now = DateTime(2026, 7, 26, 12, 0);
      final snaps = [
        ('today-early', ms(now.subtract(const Duration(hours: 6)))),
        ('today-late', ms(now)),
      ];
      final sel = selectGfs(snaps, nowMs: ms(now));
      expect(sel.keepIds, contains('today-late'));
      expect(sel.deleteIds, contains('today-early'));
    });

    test('周级：最近 4 周每周保留最新一份；更老的由月级接管', () {
      final now = DateTime(2026, 7, 26); // 周日
      final snaps = [
        // 本周 2 份
        ('w0-a', ms(now.subtract(const Duration(days: 1)))),
        ('w0-b', ms(now)),
        // 1 周前、2 周前、3 周前、5 周前各 1 份，14 个月前 1 份
        ('w1', ms(now.subtract(const Duration(days: 8)))),
        ('w2', ms(now.subtract(const Duration(days: 15)))),
        ('w3', ms(now.subtract(const Duration(days: 22)))),
        ('w5', ms(now.subtract(const Duration(days: 36)))),
        ('ancient', ms(DateTime(2025, 5, 15))),
      ];
      final sel = selectGfs(snaps, nowMs: ms(now));
      // 最近 4 周每周有一份保留
      expect(sel.keepIds, containsAll(['w0-b', 'w1', 'w2', 'w3']));
      // w5 超出 4 周但落在最近 12 个月 → 月级保留
      expect(sel.keepIds, contains('w5'));
      // 14 个月前：任何级都不覆盖 → 删除
      expect(sel.deleteIds, contains('ancient'));
    });

    test('月级：最近 12 个月每月保留最新一份', () {
      final now = DateTime(2026, 7, 26);
      final snaps = [
        for (var i = 0; i < 15; i++)
          ('m-$i', ms(DateTime(now.year, now.month - i, 15))),
      ];
      final sel = selectGfs(snaps, nowMs: ms(now));
      for (var i = 0; i < 12; i++) {
        expect(sel.keepIds, contains('m-$i'), reason: 'm-$i kept');
      }
      expect(sel.deleteIds, containsAll(['m-12', 'm-13', 'm-14']));
    });

    test('多级命中：月快照同时也是周日快照不重复计数', () {
      final now = DateTime(2026, 7, 26);
      final snaps = [
        ('today', ms(now)),
        ('month-ago', ms(DateTime(2026, 6, 26))),
      ];
      final sel = selectGfs(snaps, nowMs: ms(now));
      expect(sel.deleteIds, isEmpty);
    });

    test('空列表与单份', () {
      final now = DateTime(2026, 7, 26);
      expect(selectGfs(const [], nowMs: ms(now)).deleteIds, isEmpty);
      final sel = selectGfs([('only', ms(now))], nowMs: ms(now));
      expect(sel.keepIds, {'only'});
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shepaw/services/local_database_service.dart';
import 'package:shepaw/services/password_service.dart';
import 'package:shepaw/storage/scheduled_snapshot_service.dart';
import 'package:shepaw/storage/snapshot_crypto.dart';
import 'package:shepaw/storage/snapshot_service.dart';

import 'test_harness.dart';

/// 定期快照 + GFS + 密码变更策略（docs/storage_space_plan.md §5.1/§5.2）。
void main() {
  setUpAll(() async {
    await StorageTestHarness.init();
    await LocalDatabaseService().database;
  });

  group('checkNow', () {
    test('无缓存密钥时跳过；验密缓存后自动生成当日快照', () async {
      await SnapshotCrypto.clearCachedPasswordHash();
      expect(await ScheduledSnapshotService.instance.checkNow(), isFalse);

      // 手动验密（等同手动快照路径）后缓存 H
      final h = await SnapshotCrypto.hashPassword('scheduled-pw');
      await SnapshotCrypto.cachePasswordHash(h);

      final before = await SnapshotService.instance.listSnapshots();
      expect(await ScheduledSnapshotService.instance.checkNow(), isTrue);
      final after = await SnapshotService.instance.listSnapshots();
      expect(after.length, before.length + 1);

      // 同一天再检查：跳过
      expect(await ScheduledSnapshotService.instance.checkNow(), isFalse);
    });

    test('禁用时跳过', () async {
      await ScheduledSnapshotService.instance.setEnabled(false);
      expect(await ScheduledSnapshotService.instance.checkNow(), isFalse);
      await ScheduledSnapshotService.instance.setEnabled(true);
    });

    test('isPreferredNetwork：仅 wifi/ethernet', () {
      expect(
          ScheduledSnapshotService.isPreferredNetwork(
              [ConnectivityResult.wifi]),
          isTrue);
      expect(
          ScheduledSnapshotService.isPreferredNetwork(
              [ConnectivityResult.ethernet]),
          isTrue);
      expect(
          ScheduledSnapshotService.isPreferredNetwork(
              [ConnectivityResult.mobile]),
          isFalse);
      expect(
          ScheduledSnapshotService.isPreferredNetwork(
              [ConnectivityResult.none]),
          isFalse);
      expect(
          ScheduledSnapshotService.isPreferredNetwork(
              [ConnectivityResult.mobile, ConnectivityResult.wifi]),
          isTrue);
    });
  });

  group('GFS 清理', () {
    test('pruneGfs 删除超出保留策略的快照', () async {
      // 造 10 个"每天一份"的假快照目录
      final root = await SnapshotService.instance.deviceStoreRoot();
      final backups = Directory(p.join(root.path, 'backups'));
      final now = DateTime.now().toUtc();
      for (var i = 0; i < 10; i++) {
        final t = now.subtract(Duration(days: i));
        String two(int v) => v.toString().padLeft(2, '0');
        final id =
            '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
        final dir = Directory(p.join(backups.path, id));
        await dir.create(recursive: true);
        await File(p.join(dir.path, 'manifest.json')).writeAsString(
            '{"device_id":"x","created_at":${t.millisecondsSinceEpoch},'
            '"db_sha256":"0","files":{},"tree_root":"0"}');
      }
      final removed = await ScheduledSnapshotService.instance.pruneGfs();
      expect(removed, greaterThanOrEqualTo(2)); // 7 天之外且非周/月级的被清
      final remaining = (await SnapshotService.instance.listSnapshots())
          .map((s) => s.id)
          .toList();
      // 今天的保留
      expect(remaining.any((id) => id.startsWith(
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}')), isTrue);
    });
  });

  group('密码变更策略（§5.2）', () {
    test('改密后：新密钥全量快照自动落地；旧快照需旧密码', () async {
      final oldPw = 'old-master-pw';
      final newPw = 'new-master-pw';
      // 旧密码快照，并把 created_at 拨到 5 天前——同日快照按 GFS 只留最新
      // 一份（规格行为），改密场景关心的是更早日期的旧快照各用其钥。
      final oldSnap = await SnapshotService.instance
          .createSnapshot(password: oldPw);
      final backdated = DateTime.now()
          .toUtc()
          .subtract(const Duration(days: 5))
          .millisecondsSinceEpoch;
      final manifestFile = File(p.join(oldSnap.path, 'manifest.json'));
      final manifestJson =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      manifestJson['created_at'] = backdated;
      await manifestFile.writeAsString(jsonEncode(manifestJson));

      // 确定性触发改密处理（事件链路：PasswordService.setPassword 广播 →
      // 本服务的 onPasswordChanged；此处直调避免异步时序）
      await ScheduledSnapshotService.instance.onPasswordChanged(newPw);

      // 新快照存在（id 与旧快照不同）且能用新密码解密
      final list = await SnapshotService.instance.listSnapshots();
      final latest = list.first; // 新→旧
      expect(latest.id, isNot(oldSnap.id));
      final db = await SnapshotService.instance.decryptDb(latest, newPw);
      expect(db.isNotEmpty, isTrue);

      // 旧快照未被 GFS 清掉（5 天前，日级窗口内）
      expect(list.any((s) => s.id == oldSnap.id), isTrue);
      // 旧快照：新密码解不开，旧密码可解（各用其钥）
      expect(() => SnapshotService.instance.decryptDb(oldSnap, newPw),
          throwsA(anything));
      expect(
          (await SnapshotService.instance.decryptDb(oldSnap, oldPw)).isNotEmpty,
          isTrue);

      // passwordChangedAt 已记录（UI 标注用）
      expect(await ScheduledSnapshotService.instance.passwordChangedAtMs(),
          greaterThan(0));
    });

    test('PasswordService.setPassword 广播改密事件', () async {
      final events = <String>[];
      final sub = PasswordService().passwordChangedEvents.listen(events.add);
      await PasswordService().setPassword('broadcast-pw');
      await Future.delayed(const Duration(milliseconds: 50));
      expect(events, contains('broadcast-pw'));
      await sub.cancel();
    });
  });

  group('状态与告警', () {
    test('status 反映密钥缓存与失败计数', () async {
      final status = await ScheduledSnapshotService.instance.status();
      expect(status.enabled, isTrue);
      expect(status.keyCached, isTrue); // 改密流程已缓存
      expect(status.consecutiveFailures, 0);
      expect(status.needsAttention, isFalse);
      expect(status.enabledAtMs, greaterThan(0));
    });

    test('needsAttention：从未成功且启用超 3 天 → 告警', () {
      final enabledAt = DateTime.now()
          .subtract(const Duration(days: 4))
          .millisecondsSinceEpoch;
      final status = ScheduledSnapshotStatus(
        enabled: true,
        lastSuccessMs: 0,
        consecutiveFailures: 0,
        keyCached: true,
        enabledAtMs: enabledAt,
      );
      expect(status.needsAttention, isTrue);
      expect(
          status.needsAttentionAt(
              DateTime.fromMillisecondsSinceEpoch(enabledAt)
                  .add(const Duration(days: 2))),
          isFalse);
    });

    test('needsAttention：上次成功超 3 天 → 告警', () {
      final last = DateTime.now()
          .subtract(const Duration(days: 4))
          .millisecondsSinceEpoch;
      final status = ScheduledSnapshotStatus(
        enabled: true,
        lastSuccessMs: last,
        consecutiveFailures: 0,
        keyCached: true,
        enabledAtMs: last - const Duration(days: 30).inMilliseconds,
      );
      expect(status.needsAttention, isTrue);
    });

    test('needsAttention：同日连续失败次数不触发告警', () {
      final recent = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      final status = ScheduledSnapshotStatus(
        enabled: true,
        lastSuccessMs: recent,
        consecutiveFailures: 5,
        keyCached: true,
        enabledAtMs: recent,
      );
      expect(status.needsAttention, isFalse);
    });

    test('needsAttention：无密钥或禁用不告警', () {
      final old = DateTime.now()
          .subtract(const Duration(days: 10))
          .millisecondsSinceEpoch;
      expect(
          ScheduledSnapshotStatus(
            enabled: true,
            lastSuccessMs: old,
            consecutiveFailures: 0,
            keyCached: false,
            enabledAtMs: old,
          ).needsAttention,
          isFalse);
      expect(
          ScheduledSnapshotStatus(
            enabled: false,
            lastSuccessMs: old,
            consecutiveFailures: 0,
            keyCached: true,
            enabledAtMs: old,
          ).needsAttention,
          isFalse);
    });
  });
}

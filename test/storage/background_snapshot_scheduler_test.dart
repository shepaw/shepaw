@Tags(['needs-plugins'])
library;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/storage/background_snapshot_scheduler.dart';
import 'package:shepaw/storage/scheduled_snapshot_service.dart';

/// 系统 BG 日快照钩子（附录 A.53）。依赖 path_provider / 平台通道，本地可单独跑。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('BackgroundSnapshotScheduler 任务 id 与前台入口常量对齐', () {
    expect(BackgroundSnapshotScheduler.taskUniqueName,
        'com.shepaw.app.daily_snapshot');
    expect(BackgroundSnapshotScheduler.taskName, 'daily_snapshot');
    expect(BackgroundSnapshotScheduler.frequency, const Duration(hours: 12));
  });

  test('日快照网络约束与 isPreferredNetwork 一致（WiFi/以太网）', () {
    expect(
      ScheduledSnapshotService.isPreferredNetwork(
          [ConnectivityResult.wifi]),
      isTrue,
    );
    expect(
      ScheduledSnapshotService.isPreferredNetwork(
          [ConnectivityResult.ethernet]),
      isTrue,
    );
    expect(
      ScheduledSnapshotService.isPreferredNetwork(
          [ConnectivityResult.mobile]),
      isFalse,
    );
  });
}

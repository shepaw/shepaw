import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../services/logger_service.dart';
import 'scheduled_snapshot_service.dart';
import 'store_service.dart';

/// 系统级后台日快照调度（§13 / 附录 A.53）。
///
/// - Android：WorkManager 周期性任务（`NetworkType.unmetered` ≈ 优先 WiFi）
/// - iOS：BGAppRefresh（workmanager `registerPeriodicTask`）
/// - 不替代前台路径（启动 / 6h Timer / 回前台 / WiFi settled）；失败仍走 3 天墙钟告警
/// - 桌面：no-op
class BackgroundSnapshotScheduler {
  BackgroundSnapshotScheduler._();

  static const taskUniqueName = 'com.shepaw.app.daily_snapshot';
  static const taskName = 'daily_snapshot';

  /// 约半日一次；与「日快照」同入口去重（同日已成功则 [checkNow] 直接返回）。
  static const frequency = Duration(hours: 12);

  static final _log = LoggerService();
  static bool _registered = false;

  static bool get isSupportedPlatform =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// 由 [ScheduledSnapshotService.ensureStarted] 调用；幂等。
  static Future<void> ensureRegistered() async {
    if (_registered || !isSupportedPlatform) return;
    try {
      await Workmanager().initialize(callbackDispatcher);
      await Workmanager().registerPeriodicTask(
        taskUniqueName,
        taskName,
        frequency: frequency,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.unmetered),
      );
      _registered = true;
      _log.info('background daily snapshot registered ($taskUniqueName)',
          tag: 'BgSnapshot');
    } catch (e, st) {
      _log.warning('background snapshot register failed: $e', tag: 'BgSnapshot');
      _log.debug('$st', tag: 'BgSnapshot');
    }
  }

  /// 后台 isolate 入口：与前台同一去重逻辑。
  @visibleForTesting
  static Future<bool> runCheckNowOnPreferredNetwork() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await StoreService.instance.start();
    } catch (_) {
      // 后台冷启可能缺 peer 管线；日快照本身只依赖本机 store / KV / 密钥缓存
    }
    return ScheduledSnapshotService.instance.checkNowOnPreferredNetwork();
  }
}

/// workmanager 顶层回调（必须 top-level + `@pragma('vm:entry-point')`）。
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      if (task == BackgroundSnapshotScheduler.taskName ||
          task == BackgroundSnapshotScheduler.taskUniqueName ||
          task == Workmanager.iOSBackgroundTask) {
        await BackgroundSnapshotScheduler.runCheckNowOnPreferredNetwork();
      }
      return true;
    } catch (e, st) {
      // 返回 true 避免 OS 过度重试；漏跑由 3 天墙钟告警兜底
      debugPrint('BgSnapshot task failed: $e\n$st');
      return true;
    }
  });
}
